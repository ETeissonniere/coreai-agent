from __future__ import annotations

import argparse
import asyncio
import gc
import hashlib
import json
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import torch
from coreai_models.export import macos as macos_export
from coreai_models.export.compression import quantize_pytorch_model
from coreai_models.export.externalize import EXTERNALIZE_SPECS

sys.path.insert(0, str(Path(__file__).parent))

from nemotron_h import NemotronHConfig, NemotronHCoreAIDecode, strict_load_checkpoint

REVISION = "dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f"
MODEL_ID = "nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16"
ASSET_NAME = "nemotron_3_nano_4b_decode_int8hu"
PREFILL_CHUNK = 16
PINNED_INPUT_SHA256 = {
    "config.json": "fde9241f66cd414458df444a80eb535f53aef2b4b240a91f092e651fa6f27219",
    "tokenizer.json": "623c34567aebb18582765289fbe23d901c62704d6518d71866e0e58db892b5b7",
    "tokenizer_config.json": "48de4056b0b17de26e03232fdc1f55b70595c9354ceb2ed061f724f45620aa41",
    "special_tokens_map.json": "e3a4f63da745f02317a45e00e6476c17fc66ac41faf14bb1b0be1f3211b0ca53",
    "chat_template.jinja": "ab7813c3abdd9cb655905a410728b26c7884eca45ddfab8d9f931553485a7862",
    "model.safetensors": "55d4e2519456c4a9bddf596b0748d630e3b2ce6ff6f4c2b7ed3e07e2b00dad42",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_checkpoint(checkpoint: Path) -> None:
    for name, expected in PINNED_INPUT_SHA256.items():
        path = checkpoint / name
        if not path.is_file():
            raise FileNotFoundError(f"pinned checkpoint input is missing: {path}")
        actual = sha256(path)
        if actual != expected:
            raise ValueError(
                f"pinned checkpoint digest mismatch for {name}: {actual} != {expected}"
            )


def reference_inputs(
    config: NemotronHConfig,
    cache_length: int,
    state_dtype: torch.dtype,
    query_length: int = 1,
) -> dict[str, torch.Tensor]:
    mamba_count = config.layer_types.count("mamba")
    attention_count = config.layer_types.count("attention")
    return {
        "input_ids": torch.ones(1, query_length, dtype=torch.int32),
        "position_ids": torch.arange(cache_length, dtype=torch.int32).unsqueeze(0),
        "key_cache": torch.zeros(
            attention_count,
            1,
            config.num_key_value_heads,
            cache_length,
            config.attention_head_dim,
            dtype=state_dtype,
        ),
        "value_cache": torch.zeros(
            attention_count,
            1,
            config.num_key_value_heads,
            cache_length,
            config.attention_head_dim,
            dtype=state_dtype,
        ),
        "mamba_convolution": torch.zeros(
            mamba_count,
            1,
            config.mamba.conv_dim,
            config.mamba.conv_kernel - 1,
            dtype=state_dtype,
        ),
        "mamba_recurrent": torch.zeros(
            mamba_count,
            1,
            config.mamba.num_heads,
            config.mamba.head_dim,
            config.mamba.state_size,
            dtype=state_dtype,
        ),
    }


def dynamic_shapes(max_context: int, min_context: int = 1) -> dict[str, object]:
    return {
        "input_ids": None,
        "position_ids": {
            1: torch.export.Dim(
                "position_length", min=min_context, max=max_context
            )
        },
        "key_cache": {
            3: torch.export.Dim(
                "key_cache_length", min=min_context, max=max_context
            )
        },
        "value_cache": {
            3: torch.export.Dim(
                "value_cache_length", min=min_context, max=max_context
            )
        },
        "mamba_convolution": None,
        "mamba_recurrent": None,
    }


def export_spec(
    config: NemotronHConfig,
    cache_length: int,
    state_dtype: torch.dtype,
    max_context: int,
    query_length: int,
) -> dict[str, object]:
    return {
        "reference_inputs": reference_inputs(
            config, cache_length, state_dtype, query_length
        ),
        "dynamic_shapes": dynamic_shapes(max_context, query_length),
        "input_names": ("input_ids", "position_ids"),
        "output_names": ("logits",),
        "state_names": (
            "keyCache",
            "valueCache",
            "mambaConvolution",
            "mambaRecurrent",
        ),
    }


def nemotron_externalization_specs() -> list[object]:
    """Keep only composite operations exercised by Nemotron-H."""
    unused = {"gated_delta_update", "rope", "gather_mm"}
    return [spec for spec in EXTERNALIZE_SPECS if spec.composite_op_name not in unused]


def export_nemotron_multifunction(
    model: torch.nn.Module,
    config: NemotronHConfig,
    cache_length: int,
    state_dtype: torch.dtype,
    max_context: int,
) -> object:
    specs = nemotron_externalization_specs()
    entries = [
        ("main", export_spec(config, cache_length, state_dtype, max_context, 1)),
        (
            "prefill",
            export_spec(
                config,
                cache_length,
                state_dtype,
                max_context,
                PREFILL_CHUNK,
            ),
        ),
    ]
    model.eval()
    converter = macos_export.coreai_torch.TorchConverter(
        mode=macos_export.coreai_torch.TorchConverter.Mode.RELEASE
    )
    for entrypoint_name, spec in entries:
        def export_fn(
            module: torch.nn.Module,
            reference_inputs=spec["reference_inputs"],
            dynamic_shapes=spec["dynamic_shapes"],
        ) -> torch.export.ExportedProgram:
            with torch.no_grad():
                program = torch.export.export(
                    module,
                    args=(),
                    kwargs=reference_inputs,
                    dynamic_shapes=dynamic_shapes,
                )
            program = program.run_decompositions(
                macos_export.coreai_torch.get_decomp_table()
            )
            macos_export.remove_functionalization(program)
            return program

        converter.add_pytorch_module(
            model,
            export_fn=export_fn,
            externalize_modules=specs,
            input_names=spec["input_names"],
            output_names=spec["output_names"],
            state_names=spec["state_names"],
            entrypoint_name=entrypoint_name,
        )
    macos_export.register_custom_torch_lowering(converter)
    return converter.to_coreai()


def int8_quantization_config() -> dict[str, object]:
    """Selective GPU-friendly weight compression for Nemotron-H.

    The recurrent/attention composites, normalization, embeddings and depthwise
    convolution remain FP16. Linear body weights use clipped symmetric INT8;
    the fat-tailed untied vocabulary head uses absmax symmetric INT8.
    """
    body_weight = {
        "dtype": "int8",
        "qscheme": "symmetric_with_clipping",
        "granularity": {"type": "per_block", "block_size": 32, "axis": 1},
    }
    head_weight = {
        "dtype": "int8",
        "qscheme": "symmetric",
        "granularity": {"type": "per_block", "block_size": 32, "axis": 1},
    }
    return {
        "execution_mode": "eager",
        "global_config": {
            "op_state_spec": {"weight": body_weight},
            "op_input_spec": None,
            "op_output_spec": None,
        },
        "module_type_configs": {
            "coreai_models.primitives.macos.sdpa.SDPA": None,
            "coreai_models.primitives.macos.rms_norm.RMSNorm": None,
            "torch.nn.modules.sparse.Embedding": None,
            "torch.nn.modules.conv.Conv1d": None,
        },
        "module_name_configs": {
            r".*lm_head$": {
                "op_state_spec": {"weight": head_weight},
                "op_input_spec": None,
                "op_output_spec": None,
            }
        },
    }


def write_bundle_metadata(output: Path, checkpoint: Path, max_context: int) -> None:
    tokenizer_output = output / "tokenizer"
    tokenizer_output.mkdir(parents=True, exist_ok=True)
    for name in (
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "chat_template.jinja",
    ):
        source = checkpoint / name
        shutil.copy2(source, tokenizer_output / name)
    metadata = {
        "metadata_version": "0.2",
        "kind": "llm",
        "name": ASSET_NAME,
        "assets": {"main": f"{ASSET_NAME}.aimodel"},
        "language": {
            "tokenizer": MODEL_ID,
            "vocab_size": 131072,
            "max_context_length": max_context,
            "embedded_tokenizer": True,
            "function_map": {"main": ["main"], "prefill": ["prefill"]},
            "prefill_chunk_length": PREFILL_CHUNK,
            "prefill_chunk_lengths": [PREFILL_CHUNK],
        },
        "source": {
            "model_definition": "torch",
            "hf_model_id": MODEL_ID,
            "revision": REVISION,
        },
        "compression": "int8-body-clipped-head-absmax-per-block-32",
        "compilation": {
            "date": datetime.now(timezone.utc).isoformat(),
            "targets": ["macOS"],
            "graph": f"shared-weight S=1 decode and S={PREFILL_CHUNK} prefill",
        },
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


async def export(args: argparse.Namespace) -> None:
    checkpoint = args.checkpoint.resolve()
    validate_checkpoint(checkpoint)
    final_output = args.output.resolve()
    output = final_output.with_name(f"{final_output.name}.partial")
    if final_output.exists():
        raise FileExistsError(f"refusing to overwrite existing export: {final_output}")
    if output.exists():
        raise FileExistsError(
            f"remove or inspect the previous partial export before retrying: {output}"
        )
    config = NemotronHConfig.from_checkpoint(checkpoint)
    mamba_scan_dtype = {
        "fp16": torch.float16,
        "fp32": torch.float32,
    }[args.mamba_scan_dtype]
    original_dtype = torch.get_default_dtype()
    output.mkdir(parents=True, exist_ok=True)
    bf16_path = output / f"{ASSET_NAME}_bf16.aimodel"
    if not args.skip_bf16:
        print(
            f"[{time.strftime('%H:%M:%S')}] allocating "
            f"{sum(1 for _ in config.layer_types)} layers as BF16"
        )
        torch.set_default_dtype(torch.bfloat16)
        try:
            model = NemotronHCoreAIDecode(
                config, mamba_scan_dtype=mamba_scan_dtype
            ).eval()
        finally:
            torch.set_default_dtype(original_dtype)
        print(f"[{time.strftime('%H:%M:%S')}] strict-loading pinned checkpoint")
        strict_load_checkpoint(model, checkpoint)
        print(
            f"[{time.strftime('%H:%M:%S')}] torch.export + Core AI conversion started"
        )
        started = time.perf_counter()
        program = export_nemotron_multifunction(
            model,
            config,
            args.trace_cache_length,
            torch.bfloat16,
            args.max_context,
        )
        print(
            f"[{time.strftime('%H:%M:%S')}] BF16 conversion complete in "
            f"{time.perf_counter() - started:.1f}s"
        )
        started = time.perf_counter()
        program.save_asset(bf16_path)
        print(
            f"[{time.strftime('%H:%M:%S')}] BF16 asset saved in "
            f"{time.perf_counter() - started:.1f}s"
        )
        del program, model
        gc.collect()
    # Quantize the PyTorch graph before Core AI export. Post-export blanket INT4
    # compression was both slower and less accurate for this architecture.
    torch.set_default_dtype(torch.float16)
    try:
        quantization_model = NemotronHCoreAIDecode(
            config, mamba_scan_dtype=mamba_scan_dtype
        ).eval()
    finally:
        torch.set_default_dtype(original_dtype)
    strict_load_checkpoint(quantization_model, checkpoint)
    quantization_refs = reference_inputs(config, args.trace_cache_length, torch.float16)
    print(f"[{time.strftime('%H:%M:%S')}] selective INT8 PyTorch quantization started")
    quantization_inputs = tuple(quantization_refs.values())
    quantization_model = quantize_pytorch_model(
        quantization_model,
        quantization_inputs,
        dynamic_shapes(args.max_context),
        int8_quantization_config(),
        cache_seq_len=args.trace_cache_length,
        state_indices=(2, 3, 4, 5),
    )
    print(f"[{time.strftime('%H:%M:%S')}] INT8 Core AI conversion started")
    program = export_nemotron_multifunction(
        quantization_model,
        config,
        args.trace_cache_length,
        torch.float16,
        args.max_context,
    )
    int8_path = output / f"{ASSET_NAME}.aimodel"
    program.optimize()
    program.save_asset(int8_path)
    write_bundle_metadata(output, checkpoint, args.max_context)
    paths = (int8_path,) if args.skip_bf16 else (bf16_path, int8_path)
    for path in paths:
        size = sum(item.stat().st_size for item in path.rglob("*") if item.is_file())
        print(f"{path}: {size / 1e9:.3f} GB")
    output.replace(final_output)
    print(f"promoted validated export to {final_output}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path(".build/checkpoints/NVIDIA-Nemotron-3-Nano-4B-BF16"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(".build/exports") / ASSET_NAME,
    )
    parser.add_argument("--max-context", type=int, default=4096)
    parser.add_argument("--trace-cache-length", type=int, default=256)
    parser.add_argument("--skip-bf16", action="store_true")
    parser.add_argument("--mamba-scan-dtype", choices=("fp16", "fp32"), default="fp32")
    asyncio.run(export(parser.parse_args()))


if __name__ == "__main__":
    main()
