.PHONY: preflight download export export-title-model test test-supply-chain build package benchmark

preflight:
	./scripts/preflight.sh

download:
	./scripts/download-model.sh

export:
	./scripts/export-model.sh

export-title-model:
	./scripts/export-title-model.sh

test:
	swift test

test-supply-chain:
	./scripts/test-supply-chain.sh

build:
	swift build -c release

package: build
	./scripts/package-app.sh

benchmark:
	@test -n "$(MODEL)" || (echo "Usage: make benchmark MODEL=/path/to/model-bundle" >&2; exit 2)
	COREAI_CHUNK_THRESHOLD=1 swift run -c release qwen-canary "$(MODEL)" "Reply with exactly: Core AI is running."
