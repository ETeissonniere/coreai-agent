import torch
from transformers.cache_utils import DynamicCache
from transformers.models.nemotron_h.configuration_nemotron_h import NemotronHConfig
from transformers.models.nemotron_h.modeling_nemotron_h import (
    NemotronHMamba2Mixer as HFMamba2Mixer,
)

from nemotron_h_mamba2 import (
    FixedImplementation,
    Mamba2Config,
    Mamba2State,
    NemotronHMamba2Mixer,
    dense_parallel_scan,
    sequential_scan,
)


def make_case(sequence_length: int = 19):
    torch.manual_seed(7)
    config = Mamba2Config(chunk_size=8)
    model = NemotronHMamba2Mixer(config).eval()
    inputs = torch.randn(1, sequence_length, config.hidden_size)
    state = Mamba2State.zeros(config, 1)
    return config, model, inputs, state


def test_parallel_prefill_matches_sequential_recurrence():
    _, model, inputs, state = make_case()
    expected = model(inputs, state.convolution, state.recurrent, "sequential")
    for implementation in ("dense", "chunked"):
        actual = model(inputs, state.convolution, state.recurrent, implementation)
        for expected_tensor, actual_tensor in zip(expected, actual, strict=True):
            torch.testing.assert_close(actual_tensor, expected_tensor, atol=2e-5, rtol=2e-5)


def test_scan_matches_closed_form_and_applies_discretized_injection():
    x = torch.tensor([[[[3.0]], [[5.0]]]])
    log_a = torch.log(torch.tensor([[[0.5], [0.25]]]))
    discretized_b = torch.tensor([[[[2.0]], [[4.0]]]])
    c = torch.ones_like(discretized_b)
    initial = torch.tensor([[[[7.0]]]])
    expected_states = torch.tensor([9.5, 22.375])

    sequential, final = sequential_scan(x, log_a, discretized_b, c, initial)
    dense, dense_final = dense_parallel_scan(x, log_a, discretized_b, c, initial)
    torch.testing.assert_close(sequential.flatten(), expected_states)
    torch.testing.assert_close(dense, sequential)
    torch.testing.assert_close(final, dense_final)


def test_prefill_state_continues_single_token_decode():
    _, model, inputs, state = make_case()
    full = model(inputs, state.convolution, state.recurrent, "sequential")
    prefix = model(inputs[:, :-1], state.convolution, state.recurrent, "chunked")
    decoded = model(inputs[:, -1:], prefix[1], prefix[2], "sequential")
    torch.testing.assert_close(decoded[0], full[0][:, -1:], atol=2e-5, rtol=2e-5)
    torch.testing.assert_close(decoded[1], full[1], atol=2e-5, rtol=2e-5)
    torch.testing.assert_close(decoded[2], full[2], atol=2e-5, rtol=2e-5)


def test_torch_export_captures_prefill_and_decode():
    config, model, inputs, state = make_case(16)
    prefill = FixedImplementation(model, "chunked")
    exported_prefill = torch.export.export(
        prefill, (inputs, state.convolution, state.recurrent)
    )
    assert exported_prefill.graph_module is not None

    decode_inputs = inputs[:, :1]
    decode = FixedImplementation(model, "sequential")
    exported_decode = torch.export.export(
        decode, (decode_inputs, state.convolution, state.recurrent)
    )
    assert exported_decode.graph_module is not None


def test_prefill_and_recurrent_decode_match_hugging_face():
    torch.manual_seed(29)
    config = Mamba2Config(chunk_size=64)
    hf_config = NemotronHConfig(
        hidden_size=config.hidden_size,
        layers_block_type=["mamba"],
        mamba_num_heads=config.num_heads,
        mamba_head_dim=config.head_dim,
        ssm_state_size=config.state_size,
        n_groups=config.num_groups,
        conv_kernel=config.conv_kernel,
        chunk_size=config.chunk_size,
        use_mamba_kernels=False,
        num_attention_heads=config.num_heads,
        num_key_value_heads=config.num_groups,
        head_dim=config.head_dim,
        intermediate_size=64,
    )
    reference = HFMamba2Mixer(hf_config, layer_idx=0).eval()
    with torch.no_grad():
        reference.dt_bias.fill_(-3.0)
    model = NemotronHMamba2Mixer(config).eval()
    with torch.no_grad():
        model.in_proj.weight.copy_(reference.in_proj.weight)
        model.conv1d.weight.copy_(reference.conv1d.weight)
        model.conv1d.bias.copy_(reference.conv1d.bias)
        model.dt_bias.copy_(reference.dt_bias)
        model.A_log.copy_(reference.A_log)
        model.D.copy_(reference.D)
        model.norm_weight.copy_(reference.norm.weight)
        model.out_proj.weight.copy_(reference.out_proj.weight)

    prompt = torch.randn(1, 19, config.hidden_size)
    decode_token = torch.randn(1, 1, config.hidden_size)
    state = Mamba2State.zeros(config, 1)
    # Token-by-token HF execution is an independent oracle for both returned
    # outputs and persistent recurrent state.
    hf_cache = DynamicCache(config=hf_config)
    with torch.no_grad():
        hf_tokens = [
            reference(prompt[:, token : token + 1], cache_params=hf_cache)
            for token in range(prompt.shape[1])
        ]
        hf_prefill = torch.cat(hf_tokens, dim=1)
        hf_prefill_state = hf_cache.layers[0].recurrent_states.clone()
        prefill = model(prompt, state.convolution, state.recurrent, "chunked")
        hf_decode = reference(decode_token, cache_params=hf_cache)
        decode = model(decode_token, prefill[1], prefill[2], "sequential")

    torch.testing.assert_close(prefill[0], hf_prefill, atol=3e-5, rtol=3e-5)
    torch.testing.assert_close(prefill[2], hf_prefill_state, atol=3e-5, rtol=3e-5)
    torch.testing.assert_close(decode[0], hf_decode, atol=3e-5, rtol=3e-5)
