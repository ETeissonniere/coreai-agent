import json

import export_full_model
import pytest
import torch
from nemotron_h import (
    NemotronHAttention,
    NemotronHConfig,
    NemotronHForCausalLM,
    NemotronHState,
    strict_load_checkpoint,
)
from nemotron_h_mamba2 import Mamba2Config
from safetensors.torch import save_file


def tiny_config(pattern: str = "M*-") -> NemotronHConfig:
    return NemotronHConfig(
        hidden_size=16,
        num_hidden_layers=len(pattern),
        vocab_size=32,
        intermediate_size=24,
        layer_pattern=pattern,
        num_attention_heads=4,
        num_key_value_heads=2,
        attention_head_dim=4,
        rms_norm_eps=1e-5,
        mamba=Mamba2Config(
            hidden_size=16,
            num_heads=4,
            head_dim=4,
            state_size=3,
            num_groups=2,
            conv_kernel=3,
            chunk_size=4,
        ),
    )


def test_hybrid_layer_pattern_preserves_architecture_order() -> None:
    assert tiny_config().layer_types == ["mamba", "attention", "mlp"]


def test_strict_checkpoint_mapping_round_trips_all_synthetic_weights(tmp_path) -> None:
    torch.manual_seed(11)
    source = NemotronHForCausalLM(tiny_config()).eval()
    save_file(source.state_dict(), tmp_path / "model.safetensors")
    restored = NemotronHForCausalLM(tiny_config()).eval()

    strict_load_checkpoint(restored, tmp_path)

    for name, expected in source.state_dict().items():
        torch.testing.assert_close(restored.state_dict()[name], expected)


def test_attention_kv_state_matches_token_by_token_decode() -> None:
    torch.manual_seed(13)
    config = tiny_config("*")
    attention = NemotronHAttention(config).eval()
    inputs = torch.randn(1, 5, config.hidden_size)
    state = NemotronHState.empty(config, 1, dtype=inputs.dtype)

    full, full_key, full_value = attention(
        inputs, state.attention_keys[0], state.attention_values[0]
    )
    key = state.attention_keys[0]
    value = state.attention_values[0]
    pieces = []
    for index in range(inputs.shape[1]):
        output, key, value = attention(inputs[:, index : index + 1], key, value)
        pieces.append(output)

    torch.testing.assert_close(torch.cat(pieces, dim=1), full)
    torch.testing.assert_close(key, full_key)
    torch.testing.assert_close(value, full_value)


def test_hybrid_prefill_matches_token_by_token_decode() -> None:
    torch.manual_seed(17)
    config = tiny_config()
    model = NemotronHForCausalLM(config).eval()
    input_ids = torch.randint(config.vocab_size, (1, 5))

    chunk_logits, chunk_state = model(
        input_ids,
        NemotronHState.empty(config, 1, dtype=torch.float32),
        "sequential",
    )
    token_state = NemotronHState.empty(config, 1, dtype=torch.float32)
    token_logits = []
    for index in range(input_ids.shape[1]):
        logits, token_state = model(
            input_ids[:, index : index + 1], token_state, "sequential"
        )
        token_logits.append(logits)

    torch.testing.assert_close(torch.cat(token_logits, dim=1), chunk_logits)
    for chunk_values, token_values in (
        (chunk_state.mamba_convolution, token_state.mamba_convolution),
        (chunk_state.mamba_recurrent, token_state.mamba_recurrent),
        (chunk_state.attention_keys, token_state.attention_keys),
        (chunk_state.attention_values, token_state.attention_values),
    ):
        for chunk_value, token_value in zip(chunk_values, token_values, strict=True):
            torch.testing.assert_close(chunk_value, token_value)


def test_checkpoint_validation_rejects_missing_and_tampered_inputs(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(
        export_full_model, "PINNED_INPUT_SHA256", {"config.json": "bad"}
    )
    with pytest.raises(FileNotFoundError, match="missing"):
        export_full_model.validate_checkpoint(tmp_path)

    (tmp_path / "config.json").write_text(json.dumps({"hidden_size": 16}))
    with pytest.raises(ValueError, match="digest mismatch"):
        export_full_model.validate_checkpoint(tmp_path)


def test_int8_recipe_preserves_sensitive_modules_and_uses_absmax_head() -> None:
    config = export_full_model.int8_quantization_config()
    body = config["global_config"]["op_state_spec"]["weight"]
    head = config["module_name_configs"][r".*lm_head$"]["op_state_spec"]["weight"]

    assert body["dtype"] == "int8"
    assert body["qscheme"] == "symmetric_with_clipping"
    assert body["granularity"] == {
        "type": "per_block",
        "block_size": 32,
        "axis": 1,
    }
    assert head["dtype"] == "int8"
    assert head["qscheme"] == "symmetric"
    assert config["module_type_configs"]["torch.nn.modules.sparse.Embedding"] is None
    assert config["module_type_configs"]["torch.nn.modules.conv.Conv1d"] is None


def test_multifunction_specs_use_static_decode_and_prefill_queries() -> None:
    config = tiny_config()
    main = export_full_model.export_spec(config, 32, torch.float16, 128, 1)
    prefill = export_full_model.export_spec(
        config, 32, torch.float16, 128, export_full_model.PREFILL_CHUNK
    )

    assert main["reference_inputs"]["input_ids"].shape == (1, 1)
    assert prefill["reference_inputs"]["input_ids"].shape == (
        1,
        export_full_model.PREFILL_CHUNK,
    )
    assert main["dynamic_shapes"]["input_ids"] is None
    assert prefill["dynamic_shapes"]["input_ids"] is None


def test_bundle_metadata_advertises_prefill_function(tmp_path) -> None:
    checkpoint = tmp_path / "checkpoint"
    checkpoint.mkdir()
    for name in (
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "chat_template.jinja",
    ):
        (checkpoint / name).write_text("fixture")

    export_full_model.write_bundle_metadata(tmp_path / "bundle", checkpoint, 128)

    metadata = json.loads((tmp_path / "bundle" / "metadata.json").read_text())
    language = metadata["language"]
    assert language["function_map"] == {
        "main": ["main"],
        "prefill": ["prefill"],
    }
    assert language["prefill_chunk_length"] == export_full_model.PREFILL_CHUNK
    assert language["prefill_chunk_lengths"] == [export_full_model.PREFILL_CHUNK]
