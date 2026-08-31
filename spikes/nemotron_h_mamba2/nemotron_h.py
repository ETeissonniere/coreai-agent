from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import torch
from safetensors import safe_open
from torch import nn
from torch.nn import functional as F

from nemotron_h_mamba2 import Mamba2Config, NemotronHMamba2Mixer

try:
    from coreai_models.primitives._ops import mutable_slice_update
    from coreai_models.primitives.macos.cache import KVCache
    from coreai_models.primitives.macos.rms_norm import RMSNorm as CoreAIRMSNorm
    from coreai_models.primitives.macos.sdpa import SDPA
except ImportError:  # The pure PyTorch reference remains usable without Apple's package.
    KVCache = None
    mutable_slice_update = None
    CoreAIRMSNorm = None
    SDPA = None


@dataclass(frozen=True)
class NemotronHConfig:
    hidden_size: int
    num_hidden_layers: int
    vocab_size: int
    intermediate_size: int
    layer_pattern: str
    num_attention_heads: int
    num_key_value_heads: int
    attention_head_dim: int
    rms_norm_eps: float
    mamba: Mamba2Config

    @classmethod
    def from_checkpoint(cls, checkpoint: Path) -> "NemotronHConfig":
        raw = json.loads((checkpoint / "config.json").read_text())
        return cls(
            hidden_size=raw["hidden_size"],
            num_hidden_layers=raw["num_hidden_layers"],
            vocab_size=raw["vocab_size"],
            intermediate_size=raw["intermediate_size"],
            layer_pattern=raw["hybrid_override_pattern"],
            num_attention_heads=raw["num_attention_heads"],
            num_key_value_heads=raw["num_key_value_heads"],
            attention_head_dim=raw["head_dim"],
            rms_norm_eps=raw["rms_norm_eps"],
            mamba=Mamba2Config(
                hidden_size=raw["hidden_size"],
                num_heads=raw["mamba_num_heads"],
                head_dim=raw["mamba_head_dim"],
                state_size=raw["ssm_state_size"],
                num_groups=raw["n_groups"],
                conv_kernel=raw["conv_kernel"],
                chunk_size=raw["chunk_size"],
                eps=raw["rms_norm_eps"],
            ),
        )

    @property
    def layer_types(self) -> list[str]:
        names = {"M": "mamba", "*": "attention", "-": "mlp"}
        return [names[item] for item in self.layer_pattern]


@dataclass
class NemotronHState:
    mamba_convolution: list[torch.Tensor]
    mamba_recurrent: list[torch.Tensor]
    attention_keys: list[torch.Tensor]
    attention_values: list[torch.Tensor]

    @classmethod
    def empty(
        cls, config: NemotronHConfig, batch_size: int, *, dtype: torch.dtype
    ) -> "NemotronHState":
        mamba_count = config.layer_types.count("mamba")
        attention_count = config.layer_types.count("attention")
        return cls(
            mamba_convolution=[
                torch.zeros(
                    batch_size,
                    config.mamba.conv_dim,
                    config.mamba.conv_kernel - 1,
                    dtype=dtype,
                )
                for _ in range(mamba_count)
            ],
            mamba_recurrent=[
                torch.zeros(
                    batch_size,
                    config.mamba.num_heads,
                    config.mamba.head_dim,
                    config.mamba.state_size,
                    dtype=torch.float32,
                )
                for _ in range(mamba_count)
            ],
            attention_keys=[
                torch.empty(
                    batch_size,
                    config.num_key_value_heads,
                    0,
                    config.attention_head_dim,
                    dtype=dtype,
                )
                for _ in range(attention_count)
            ],
            attention_values=[
                torch.empty(
                    batch_size,
                    config.num_key_value_heads,
                    0,
                    config.attention_head_dim,
                    dtype=dtype,
                )
                for _ in range(attention_count)
            ],
        )


class TorchRMSNorm(nn.Module):
    def __init__(self, size: int, eps: float) -> None:
        super().__init__()
        self.weight = nn.Parameter(torch.ones(size))
        self.eps = eps

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        normalized = inputs.float() * torch.rsqrt(
            inputs.float().square().mean(dim=-1, keepdim=True) + self.eps
        )
        return (normalized * self.weight.float()).to(inputs.dtype)


# Use Apple's composite primitive for exported graphs while keeping the spike's
# pure-PyTorch numerical tests runnable without the Core AI package installed.
RMSNorm = CoreAIRMSNorm or TorchRMSNorm


class CoreAISSMState:
    """Fixed-shape recurrent state with a rank-correct Core AI slice update.

    Apple's current helper omits the final dimension from ``end`` for states
    with rank greater than three. Keeping this small adapter local makes the
    Nemotron exporter reproducible without patching the external checkout.
    """

    def __init__(self, states: torch.Tensor) -> None:
        self.states = states

    def update_states(self, layer_index: int, new_state: torch.Tensor) -> None:
        if mutable_slice_update is None:
            raise RuntimeError("Apple coreai-models Python package is required for export")
        rank = self.states.dim()
        begin = torch.tensor(
            [layer_index, *([0] * (rank - 1))], dtype=torch.int32
        )
        end = torch.tensor(
            [layer_index + 1, *self.states.shape[1:]], dtype=torch.int32
        )
        mutable_slice_update(
            x=self.states,
            update=new_state.unsqueeze(0),
            begin=begin,
            end=end,
        )


class NemotronHMLP(nn.Module):
    def __init__(self, config: NemotronHConfig) -> None:
        super().__init__()
        self.up_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=False)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=False)

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        activated = F.relu(self.up_proj(inputs)).square()
        return self.down_proj(activated)


class NemotronHAttention(nn.Module):
    def __init__(self, config: NemotronHConfig) -> None:
        super().__init__()
        self.num_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.head_dim = config.attention_head_dim
        self.groups = self.num_heads // self.num_key_value_heads
        self.q_proj = nn.Linear(config.hidden_size, self.num_heads * self.head_dim, bias=False)
        self.k_proj = nn.Linear(
            config.hidden_size, self.num_key_value_heads * self.head_dim, bias=False
        )
        self.v_proj = nn.Linear(
            config.hidden_size, self.num_key_value_heads * self.head_dim, bias=False
        )
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size, bias=False)
        self.sdpa = (
            SDPA(scale=self.head_dim**-0.5, is_causal=True)
            if SDPA is not None
            else None
        )

    def forward(
        self, inputs: torch.Tensor, past_key: torch.Tensor, past_value: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        batch, sequence, _ = inputs.shape
        query = self.q_proj(inputs).reshape(
            batch, sequence, self.num_heads, self.head_dim
        ).transpose(1, 2)
        key = self.k_proj(inputs).reshape(
            batch, sequence, self.num_key_value_heads, self.head_dim
        ).transpose(1, 2)
        value = self.v_proj(inputs).reshape(
            batch, sequence, self.num_key_value_heads, self.head_dim
        ).transpose(1, 2)
        key = torch.cat((past_key, key), dim=2)
        value = torch.cat((past_value, value), dim=2)
        repeated_key = key.repeat_interleave(self.groups, dim=1)
        repeated_value = value.repeat_interleave(self.groups, dim=1)

        total = key.shape[2]
        past = past_key.shape[2]
        query_positions = torch.arange(sequence, device=inputs.device) + past
        key_positions = torch.arange(total, device=inputs.device)
        mask = key_positions[None, :] <= query_positions[:, None]
        scores = torch.matmul(query.float(), repeated_key.float().transpose(-1, -2))
        scores = scores / self.head_dim**0.5
        scores = scores.masked_fill(~mask[None, None], torch.finfo(scores.dtype).min)
        probabilities = F.softmax(scores, dim=-1).to(inputs.dtype)
        output = torch.matmul(probabilities, repeated_value)
        output = output.transpose(1, 2).reshape(batch, sequence, -1)
        return self.o_proj(output), key, value

    def forward_cached(
        self,
        inputs: torch.Tensor,
        cache: object,
        layer_index: int,
        offset: int,
        sequence_length: int,
    ) -> torch.Tensor:
        batch, query_length, _ = inputs.shape
        query = self.q_proj(inputs).reshape(
            batch, query_length, self.num_heads, self.head_dim
        ).transpose(1, 2)
        key = self.k_proj(inputs).reshape(
            batch, query_length, self.num_key_value_heads, self.head_dim
        ).transpose(1, 2)
        value = self.v_proj(inputs).reshape(
            batch, query_length, self.num_key_value_heads, self.head_dim
        ).transpose(1, 2)
        key, value = cache.update_and_fetch(
            layer_index,
            offset,
            key,
            value,
            seq_len=sequence_length,
            query_len=query_length,
        )
        if self.sdpa is not None:
            output = self.sdpa(query, key, value)
        else:
            key = key.repeat_interleave(self.groups, dim=1)
            value = value.repeat_interleave(self.groups, dim=1)
            scores = torch.matmul(query.float(), key.float().transpose(-1, -2))
            scores = scores / self.head_dim**0.5
            probabilities = F.softmax(scores, dim=-1).to(inputs.dtype)
            output = torch.matmul(probabilities, value)
        output = output.transpose(1, 2).reshape(batch, query_length, -1)
        return self.o_proj(output)


class NemotronHBlock(nn.Module):
    def __init__(
        self,
        config: NemotronHConfig,
        layer_type: str,
        *,
        mamba_scan_dtype: torch.dtype = torch.float32,
    ) -> None:
        super().__init__()
        self.layer_type = layer_type
        self.norm = RMSNorm(config.hidden_size, config.rms_norm_eps)
        if layer_type == "mamba":
            self.mixer = NemotronHMamba2Mixer(
                config.mamba, scan_dtype=mamba_scan_dtype
            )
        elif layer_type == "attention":
            self.mixer = NemotronHAttention(config)
        elif layer_type == "mlp":
            self.mixer = NemotronHMLP(config)
        else:
            raise ValueError(f"unknown layer type {layer_type}")


class NemotronHBackbone(nn.Module):
    def __init__(
        self, config: NemotronHConfig, *, mamba_scan_dtype: torch.dtype = torch.float32
    ) -> None:
        super().__init__()
        self.config = config
        self.embeddings = nn.Embedding(config.vocab_size, config.hidden_size)
        self.layers = nn.ModuleList(
            NemotronHBlock(
                config, layer_type, mamba_scan_dtype=mamba_scan_dtype
            )
            for layer_type in config.layer_types
        )
        self.norm_f = RMSNorm(config.hidden_size, config.rms_norm_eps)

    def forward(
        self, input_ids: torch.Tensor, state: NemotronHState, implementation: str = "chunked"
    ) -> tuple[torch.Tensor, NemotronHState]:
        hidden = self.embeddings(input_ids)
        mamba_index = 0
        attention_index = 0
        next_convolution: list[torch.Tensor] = []
        next_recurrent: list[torch.Tensor] = []
        next_keys: list[torch.Tensor] = []
        next_values: list[torch.Tensor] = []
        for layer in self.layers:
            residual = hidden
            normalized = layer.norm(hidden)
            if layer.layer_type == "mamba":
                hidden, convolution, recurrent = layer.mixer(
                    normalized,
                    state.mamba_convolution[mamba_index],
                    state.mamba_recurrent[mamba_index],
                    implementation,
                )
                next_convolution.append(convolution)
                next_recurrent.append(recurrent)
                mamba_index += 1
            elif layer.layer_type == "attention":
                hidden, key, value = layer.mixer(
                    normalized,
                    state.attention_keys[attention_index],
                    state.attention_values[attention_index],
                )
                next_keys.append(key)
                next_values.append(value)
                attention_index += 1
            else:
                hidden = layer.mixer(normalized)
            hidden = residual + hidden
        return self.norm_f(hidden), NemotronHState(
            next_convolution, next_recurrent, next_keys, next_values
        )


class NemotronHForCausalLM(nn.Module):
    def __init__(
        self, config: NemotronHConfig, *, mamba_scan_dtype: torch.dtype = torch.float32
    ) -> None:
        super().__init__()
        self.config = config
        self.backbone = NemotronHBackbone(
            config, mamba_scan_dtype=mamba_scan_dtype
        )
        self.lm_head = nn.Linear(config.hidden_size, config.vocab_size, bias=False)

    def forward(
        self, input_ids: torch.Tensor, state: NemotronHState, implementation: str = "chunked"
    ) -> tuple[torch.Tensor, NemotronHState]:
        hidden, state = self.backbone(input_ids, state, implementation)
        return self.lm_head(hidden), state


class NemotronHCoreAIDecode(NemotronHForCausalLM):
    """One-token Core AI graph matching CoreAIPipelinedEngine's state contract."""

    def __init__(
        self, config: NemotronHConfig, *, mamba_scan_dtype: torch.dtype = torch.float32
    ) -> None:
        # ANE does not accept FP32 mutable state. Keep recurrence arithmetic in
        # FP32, but store the state as FP16 at the graph boundary.
        super().__init__(config, mamba_scan_dtype=mamba_scan_dtype)

    def forward(
        self,
        input_ids: torch.Tensor,
        position_ids: torch.Tensor,
        key_cache: torch.Tensor,
        value_cache: torch.Tensor,
        mamba_convolution: torch.Tensor,
        mamba_recurrent: torch.Tensor,
    ) -> torch.Tensor:
        if KVCache is None or mutable_slice_update is None:
            raise RuntimeError("Apple coreai-models Python package is required for export")
        kv_cache = KVCache(key_cache, value_cache)
        convolution_cache = CoreAISSMState(mamba_convolution)
        recurrent_cache = CoreAISSMState(mamba_recurrent)
        hidden = self.backbone.embeddings(input_ids)
        offset = position_ids.shape[1] - input_ids.shape[1]
        sequence_length = position_ids.shape[1]
        mamba_index = 0
        attention_index = 0
        for layer in self.backbone.layers:
            residual = hidden
            normalized = layer.norm(hidden)
            if layer.layer_type == "mamba":
                convolution = convolution_cache.states.narrow(
                    0, mamba_index, 1
                ).squeeze(0)
                recurrent = recurrent_cache.states.narrow(
                    0, mamba_index, 1
                ).squeeze(0)
                hidden, convolution, recurrent = layer.mixer(
                    normalized,
                    convolution,
                    recurrent,
                    "sequential",
                )
                convolution_cache.update_states(mamba_index, convolution)
                recurrent_cache.update_states(
                    mamba_index, recurrent.to(mamba_recurrent.dtype)
                )
                mamba_index += 1
            elif layer.layer_type == "attention":
                hidden = layer.mixer.forward_cached(
                    normalized,
                    kv_cache,
                    attention_index,
                    offset,
                    sequence_length,
                )
                attention_index += 1
            else:
                hidden = layer.mixer(normalized)
            hidden = residual + hidden
        hidden = self.backbone.norm_f(hidden)
        return self.lm_head(hidden).to(torch.float16)

def checkpoint_tensors(checkpoint: Path) -> Iterator[tuple[str, torch.Tensor]]:
    index_path = checkpoint / "model.safetensors.index.json"
    if index_path.exists():
        index = json.loads(index_path.read_text())
        filenames = sorted(set(index["weight_map"].values()))
    else:
        filenames = ["model.safetensors"]
    for filename in filenames:
        with safe_open(checkpoint / filename, framework="pt", device="cpu") as shard:
            for key in shard.keys():
                yield key, shard.get_tensor(key)


def strict_load_checkpoint(model: NemotronHForCausalLM, checkpoint: Path) -> None:
    expected = set(model.state_dict())
    loaded: set[str] = set()
    parameters = dict(model.named_parameters())
    with torch.no_grad():
        for checkpoint_key, tensor in checkpoint_tensors(checkpoint):
            model_key = checkpoint_key
            if model_key.endswith(".mixer.norm.weight"):
                model_key = model_key.replace(".mixer.norm.weight", ".mixer.norm_weight")
            if model_key not in parameters:
                raise KeyError(f"unexpected checkpoint tensor: {checkpoint_key}")
            target = parameters[model_key]
            if target.shape != tensor.shape:
                raise ValueError(
                    f"shape mismatch for {checkpoint_key}: {tuple(tensor.shape)} != {tuple(target.shape)}"
                )
            target.copy_(tensor.to(target.dtype))
            loaded.add(model_key)
    missing = expected - loaded
    if missing:
        raise KeyError(f"missing checkpoint tensors: {sorted(missing)}")
