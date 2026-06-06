PROTOC := protoc
SRC_DIR := ./src
THIRD_PARTY_DIR := ./third_party

.PHONY: init
# Init env
init:
	go install github.com/ttufo101/xrpc/cmd/xrpc@latest
	go install github.com/ttufo101/xrpc/cmd/protoc-gen-go-http@latest
	go install github.com/ttufo101/xrpc/cmd/protoc-gen-go-errors@latest
	go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
	go install github.com/envoyproxy/protoc-gen-validate@latest


.PHONY: compile
# Compile all protobuf files
compile:
	@command -v $(PROTOC) >/dev/null 2>&1 || { \
		echo "Error: $(PROTOC) is not installed. Please install it and try again."; \
		exit 1; \
	}

	@echo "Compiling all protobuf files..."
	@rm -rf "$(SRC_DIR)" && mkdir -p "$(SRC_DIR)"

	@if ! xrpc proto client -p "$(THIRD_PARTY_DIR)" -o "$(SRC_DIR)" .; then \
		echo "Error: Failed to compile protobuf files."; \
		exit 1; \
	fi

	@cd $(SRC_DIR) && go mod init github.com/ttufo101/api && go mod tidy
	@echo "All projects have been compiled successfully."


.PHONY: help
# Show help
help:
	@echo ''
	@echo 'Usage:'
	@echo ' make [target]'
	@echo ''
	@echo 'Targets:'
	@awk '/^[a-zA-Z\-\_0-9]+:/ { \
	helpMessage = match(lastLine, /^# (.*)/); \
		if (helpMessage) { \
			helpCommand = substr($$1, 0, index($$1, ":")); \
			helpMessage = substr(lastLine, RSTART + 2, RLENGTH); \
			printf "\033[36m%-22s\033[0m %s\n", helpCommand,helpMessage; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)

.DEFAULT_GOAL := compile
