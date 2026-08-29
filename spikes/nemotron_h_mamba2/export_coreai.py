from __future__ import annotations

import asyncio
import sys
import tempfile
import time
import statistics
from pathlib import Path

import torch
from coreai.runtime import NDArray
from coreai_torch import TorchConverter, get_decomp_table

sys.path.insert(0, str(Path(__file__).parent))

from nemotron_h_mamba2 import (
    FixedImplementation,
    Mamba2Config,
    Mamba2State,
    NemotronHMamba2Mixer,
)


async def export_and_run(
    implementation: str,
    sequence_length: int,
    config: Mamba2Config,
    label: str,
) -> None:
    torch.manual_seed(23)
    mixer = NemotronHMamba2Mixer(config).eval()
    model = FixedImplementation(mixer, implementation).eval()
    inputs = torch.randn(1, sequence_length, config.hidden_size)
    state = Mamba2State.zeros(config, 1)
    args = (inputs, state.convolution, state.recurrent)

    started = time.perf_counter()
    exported = torch.export.export(model, args).run_decompositions(get_decomp_table())
    converter = TorchConverter()
    converter.add_exported_program(
        exported,
        input_names=("inputs", "convolution_state", "recurrent_state"),
        output_names=("output", "new_convolution_state", "new_recurrent_state"),
    )
    program = converter.to_coreai()
    conversion_seconds = time.perf_counter() - started

    with tempfile.TemporaryDirectory() as directory:
        asset_path = Path(directory) / f"mamba2-{implementation}.aimodel"
        asset = program.save_asset(asset_path)
        asset_bytes = sum(path.stat().st_size for path in asset_path.rglob("*") if path.is_file())
        async with asset.executable() as executable:
            function = executable.load_function("main")
            coreai_inputs = {
                name: NDArray(data=tensor.contiguous())
                for name, tensor in zip(function.desc.input_names, args, strict=True)
            }
            outputs = await function(coreai_inputs)
            samples = []
            for _ in range(5):
                started = time.perf_counter()
                outputs = await function(coreai_inputs)
                samples.append(time.perf_counter() - started)
            runtime_seconds = statistics.median(samples)

    expected = model(*args)
    for name, tensor in zip(
        ("output", "new_convolution_state", "new_recurrent_state"), expected, strict=True
    ):
        torch.testing.assert_close(
            torch.from_numpy(outputs[name].numpy()), tensor, atol=2e-3, rtol=2e-3
        )
    print(
        f"PASS {label=} {implementation=} {sequence_length=} "
        f"conversion={conversion_seconds:.3f}s runtime={runtime_seconds:.6f}s "
        f"tokens_per_second={sequence_length / runtime_seconds:.2f} "
        f"asset_mib={asset_bytes / (1024 * 1024):.2f}"
    )


async def main() -> None:
    tiny = Mamba2Config(chunk_size=8)
    await export_and_run("sequential", 1, tiny, "tiny")
    await export_and_run("sequential", 16, tiny, "tiny")
    await export_and_run("dense", 16, tiny, "tiny")
    await export_and_run("chunked", 16, tiny, "tiny")

    scaled = Mamba2Config(
        hidden_size=512,
        num_heads=8,
        head_dim=64,
        state_size=64,
        num_groups=4,
        chunk_size=16,
    )
    await export_and_run("sequential", 64, scaled, "scaled")
    await export_and_run("chunked", 64, scaled, "scaled")

    nano = Mamba2Config(
        hidden_size=3136,
        num_heads=96,
        head_dim=80,
        state_size=128,
        num_groups=8,
        chunk_size=8,
    )
    await export_and_run("sequential", 1, nano, "nano-exact")
    await export_and_run("sequential", 8, nano, "nano-exact")
    await export_and_run("chunked", 8, nano, "nano-exact")
    await export_and_run("sequential", 32, nano, "nano-exact")
    await export_and_run("chunked", 32, nano, "nano-exact")


if __name__ == "__main__":
    asyncio.run(main())
