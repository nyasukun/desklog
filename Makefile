.PHONY: build app run test verify-local-only whisper-setup speaker-setup models-setup clean

build:
	swift build

app:
	./scripts/build-app.sh release

run:
	./scripts/build-app.sh debug
	open build/Desklog.app

test:
	swift test
	swift run DesklogSelfTest

verify-local-only:
	swift test --filter LocalOnlyPolicyTests
	swift test --filter ConfigurationTests
	swift test --filter CaptureReadinessGateTests
	swift test --filter CaptureExclusionPolicyTests
	swift test --filter CaptureExclusionIntegrationTests
	swift test --filter SummaryPromptTests
	swift test --filter StoragePrivacyTests
	swift test --filter LocalWhisperProcessTests
	swift test --filter LocalSpeakerHelperClientTests
	swift build -c release --product Desklog
	BIN_DIR="$$(swift build -c release --show-bin-path)"; \
		if nm "$$BIN_DIR/Desklog" | swift demangle | /usr/bin/grep -E 'SpeakerKit|ModelDownloader' >/dev/null; then \
			echo 'error: Release Desklog still links SpeakerKit/model download symbols.' >&2; exit 1; \
		fi; \
		if strings "$$BIN_DIR/Desklog" | /usr/bin/grep -F 'huggingface.co' >/dev/null; then \
			echo 'error: Release Desklog contains a remote model host.' >&2; exit 1; \
		fi
	swift build --product DesklogSelfTest
	swift build --product DesklogSpeakerHelper
	BIN_DIR="$$(swift build --show-bin-path)"; \
		DESKLOG_REQUIRE_SPEAKER_SMOKE=1 \
		"$$BIN_DIR/DesklogSelfTest"; \
		DESKLOG_REQUIRE_WHISPER_SMOKE=1 \
		sandbox-exec -p '(version 1) (allow default) (deny network*)' \
		"$$BIN_DIR/DesklogSelfTest"

whisper-setup:
	./scripts/setup-whisper.sh

speaker-setup:
	swift run DesklogModelSetup

models-setup: whisper-setup speaker-setup

clean:
	swift package clean
	rm -rf build
