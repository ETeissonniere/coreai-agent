import json

import pytest
import torch
from safetensors.torch import save_file

import export_full_model
from nemotron_h import (
    NemotronHAttention,
    NemotronHConfig,
    NemotronHForCausalLM,
    NemotronHState,
    strict_load_checkpoint,
)
from nemotron_h_mamba2 import Mamba2Config


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


def test_checkpoint_validation_rejects_missing_and_tampered_inputs(
    tmp_path, monkeypatch
) -> None:
    monkeypatch.setattr(export_full_model, "PINNED_INPUT_SHA256", {"config.json": "bad"})
    with pytest.raises(FileNotFoundError, match="missing"):
        export_full_model.validate_checkpoint(tmp_path)

    (tmp_path / "config.json").write_text(json.dumps({"hidden_size": 16}))
    with pytest.raises(ValueError, match="digest mismatch"):
        export_full_model.validate_checkpoint(tmp_path)
