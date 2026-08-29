from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import nn
from torch.nn import functional as F


@dataclass(frozen=True)
class Mamba2Config:
    hidden_size: int = 32
    num_heads: int = 4
    head_dim: int = 8
    state_size: int = 8
    num_groups: int = 2
    conv_kernel: int = 4
    chunk_size: int = 16
    eps: float = 1e-5
    # Nemotron's time_step_min/max configure dt initialization, not runtime
    # clipping. The checkpoint's runtime limit is (0, +inf).
    time_step_min: float = 0.0
    time_step_max: float = float("inf")

    @property
    def intermediate_size(self) -> int:
        return self.num_heads * self.head_dim

    @property
    def conv_dim(self) -> int:
        return self.intermediate_size + 2 * self.num_groups * self.state_size


@dataclass
class Mamba2State:
    convolution: torch.Tensor
    recurrent: torch.Tensor

    @classmethod
    def zeros(
        cls, config: Mamba2Config, batch_size: int, *, dtype: torch.dtype = torch.float32
    ) -> "Mamba2State":
        return cls(
            convolution=torch.zeros(
                batch_size,
                config.conv_dim,
                config.conv_kernel - 1,
                dtype=dtype,
            ),
            recurrent=torch.zeros(
                batch_size,
                config.num_heads,
                config.head_dim,
                config.state_size,
                dtype=torch.float32,
            ),
        )


def _expand_groups(x: torch.Tensor, num_heads: int) -> torch.Tensor:
    return x.repeat_interleave(num_heads // x.shape[2], dim=2)


def sequential_scan(
    x: torch.Tensor,
    log_a: torch.Tensor,
    b: torch.Tensor,
    c: torch.Tensor,
    initial_state: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Reference recurrence: state_t = a_t state_(t-1) + b_t x_t."""
    state = initial_state.to(x.dtype)
    outputs: list[torch.Tensor] = []
    for token in range(x.shape[1]):
        state = torch.exp(log_a[:, token, :, None, None]) * state + (
            b[:, token, :, None, :] * x[:, token, :, :, None]
        )
        outputs.append((state * c[:, token, :, None, :]).sum(dim=-1))
    return torch.stack(outputs, dim=1), state


def dense_parallel_scan(
    x: torch.Tensor,
    log_a: torch.Tensor,
    b: torch.Tensor,
    c: torch.Tensor,
    initial_state: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Loop-free O(S^2) scan expressed with Core AI-friendly tensor ops."""
    sequence_length = x.shape[1]
    prefix = torch.cumsum(log_a, dim=1)
    target = prefix[:, :, None, :]
    source = prefix[:, None, :, :]
    causal = torch.arange(sequence_length, device=x.device)
    causal = causal[:, None] >= causal[None, :]
    log_decay = torch.where(
        causal[None, :, :, None],
        target - source,
        torch.full_like(target - source, -30.0),
    )
    decay = torch.exp(log_decay) * causal[None, :, :, None]

    injection = b[:, :, :, None, :] * x[:, :, :, :, None]
    states = (
        decay[..., None, None] * injection[:, None, :, :, :, :]
    ).sum(dim=2)
    states = states + torch.exp(prefix)[..., None, None] * initial_state[:, None]
    outputs = (states * c[:, :, :, None, :]).sum(dim=-1)
    return outputs, states[:, -1]


def chunked_parallel_scan(
    x: torch.Tensor,
    log_a: torch.Tensor,
    b: torch.Tensor,
    c: torch.Tensor,
    initial_state: torch.Tensor,
    chunk_size: int,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Bounded-workspace scan; chunks are statically unrolled by torch.export."""
    state = initial_state
    outputs: list[torch.Tensor] = []
    for start in range(0, x.shape[1], chunk_size):
        end = min(start + chunk_size, x.shape[1])
        chunk_output, state = dense_parallel_scan(
            x[:, start:end],
            log_a[:, start:end],
            b[:, start:end],
            c[:, start:end],
            state,
        )
        outputs.append(chunk_output)
    return torch.cat(outputs, dim=1), state


class NemotronHMamba2Mixer(nn.Module):
    """Small, weight-compatible reauthoring of HF's Nemotron-H Mamba-2 mixer."""

    def __init__(
        self, config: Mamba2Config, *, scan_dtype: torch.dtype = torch.float32
    ) -> None:
        super().__init__()
        self.config = config
        self.scan_dtype = scan_dtype
        self.in_proj = nn.Linear(
            config.hidden_size,
            config.intermediate_size + config.conv_dim + config.num_heads,
            bias=False,
        )
        self.conv1d = nn.Conv1d(
            config.conv_dim,
            config.conv_dim,
            config.conv_kernel,
            groups=config.conv_dim,
            padding=config.conv_kernel - 1,
            bias=True,
        )
        self.dt_bias = nn.Parameter(torch.ones(config.num_heads))
        self.A_log = nn.Parameter(torch.log(torch.arange(1, config.num_heads + 1).float()))
        self.D = nn.Parameter(torch.ones(config.num_heads))
        self.norm_weight = nn.Parameter(torch.ones(config.intermediate_size))
        self.out_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=False)

    def _project_and_convolve(
        self, inputs: torch.Tensor, convolution_state: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        cfg = self.config
        projected = self.in_proj(inputs)
        gate, conv_input, dt = projected.split(
            [cfg.intermediate_size, cfg.conv_dim, cfg.num_heads], dim=-1
        )
        combined = torch.cat([convolution_state, conv_input.transpose(1, 2)], dim=-1)
        convolved = F.conv1d(
            combined,
            self.conv1d.weight,
            self.conv1d.bias,
            groups=cfg.conv_dim,
        )
        convolved = F.silu(convolved.transpose(1, 2))
        return gate, convolved, dt, conv_input

    def _scan_inputs(
        self, convolved: torch.Tensor, dt: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        cfg = self.config
        x, b, c = convolved.split(
            [
                cfg.intermediate_size,
                cfg.num_groups * cfg.state_size,
                cfg.num_groups * cfg.state_size,
            ],
            dim=-1,
        )
        x = x.reshape(x.shape[0], x.shape[1], cfg.num_heads, cfg.head_dim).to(
            self.scan_dtype
        )
        b = b.reshape(b.shape[0], b.shape[1], cfg.num_groups, cfg.state_size).to(
            self.scan_dtype
        )
        c = c.reshape(c.shape[0], c.shape[1], cfg.num_groups, cfg.state_size).to(
            self.scan_dtype
        )
        b = _expand_groups(b, cfg.num_heads)
        c = _expand_groups(c, cfg.num_heads)
        dt = F.softplus(dt + self.dt_bias).clamp(
            min=cfg.time_step_min, max=cfg.time_step_max
        ).to(self.scan_dtype)
        b = b * dt[..., None]
        log_a = dt * -torch.exp(self.A_log.to(self.scan_dtype))[None, None, :]
        return x, log_a, b, c

    def _gated_group_norm(self, hidden: torch.Tensor, gate: torch.Tensor) -> torch.Tensor:
        cfg = self.config
        hidden = hidden.to(self.scan_dtype) * F.silu(gate.to(self.scan_dtype))
        grouped = hidden.reshape(
            *hidden.shape[:-1], cfg.num_groups, cfg.intermediate_size // cfg.num_groups
        )
        grouped = grouped * torch.rsqrt(grouped.square().mean(dim=-1, keepdim=True) + cfg.eps)
        return grouped.reshape_as(hidden) * self.norm_weight

    def forward(
        self,
        inputs: torch.Tensor,
        convolution_state: torch.Tensor,
        recurrent_state: torch.Tensor,
        implementation: str = "sequential",
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        cfg = self.config
        gate, convolved, dt, conv_input = self._project_and_convolve(
            inputs, convolution_state
        )
        x, log_a, b, c = self._scan_inputs(convolved, dt)
        if implementation == "sequential":
            output, final_recurrent = sequential_scan(x, log_a, b, c, recurrent_state)
        elif implementation == "dense":
            output, final_recurrent = dense_parallel_scan(x, log_a, b, c, recurrent_state)
        elif implementation == "chunked":
            output, final_recurrent = chunked_parallel_scan(
                x, log_a, b, c, recurrent_state, cfg.chunk_size
            )
        else:
            raise ValueError(f"unknown scan implementation: {implementation}")

        output = output + x * self.D[None, None, :, None]
        output = output.reshape(inputs.shape[0], inputs.shape[1], cfg.intermediate_size)
        output = self._gated_group_norm(output, gate)
        final_convolution = torch.cat(
            [convolution_state, conv_input.transpose(1, 2)], dim=-1
        )[:, :, -(cfg.conv_kernel - 1) :]
        return self.out_proj(output.to(inputs.dtype)), final_convolution, final_recurrent


class FixedImplementation(nn.Module):
    def __init__(self, mixer: NemotronHMamba2Mixer, implementation: str) -> None:
        super().__init__()
        self.mixer = mixer
        self.implementation = implementation

    def forward(
        self,
        inputs: torch.Tensor,
        convolution_state: torch.Tensor,
        recurrent_state: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        return self.mixer(inputs, convolution_state, recurrent_state, self.implementation)
