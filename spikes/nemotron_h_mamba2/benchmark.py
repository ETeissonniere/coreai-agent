from __future__ import annotations

import statistics
import sys
import time
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).parent))

from nemotron_h_mamba2 import Mamba2Config, Mamba2State, NemotronHMamba2Mixer


def measure(function, warmup: int = 2, iterations: int = 7) -> float:
    for _ in range(warmup):
        function()
    samples = []
    for _ in range(iterations):
        start = time.perf_counter()
        function()
        samples.append(time.perf_counter() - start)
    return statistics.median(samples)


def main() -> None:
    torch.set_num_threads(1)
    torch.manual_seed(17)
    # Exact Nano mixer dimensions; synthetic weights and moderate sequence sizes.
    config = Mamba2Config(
        hidden_size=3136,
        num_heads=96,
        head_dim=80,
        state_size=128,
        num_groups=8,
        conv_kernel=4,
        chunk_size=32,
    )
    model = NemotronHMamba2Mixer(config).eval()
    print("implementation,sequence_length,seconds,tokens_per_second")
    with torch.no_grad():
        for sequence_length in (16, 32, 64):
            inputs = torch.randn(1, sequence_length, config.hidden_size)
            state = Mamba2State.zeros(config, 1)
            for implementation in ("sequential", "chunked"):
                elapsed = measure(
                    lambda: model(
                        inputs,
                        state.convolution,
                        state.recurrent,
                        implementation,
                    ),
                    warmup=1,
                    iterations=3,
                )
                print(
                    f"{implementation},{sequence_length},{elapsed:.6f},"
                    f"{sequence_length / elapsed:.2f}"
                )


if __name__ == "__main__":
    main()
