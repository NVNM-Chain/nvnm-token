# NVNM ERC-20 development and release checks.
.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help install install-security build rebuild test test-ci test-lite fmt fmt-check lint solhint slither check-deps abi test-tools coverage gas gas-check clean anvil deploy-sepolia deploy-hoodi deploy-base-sepolia deploy-mainnet deploy-base verify check release-check

help: ## Show available tasks
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-22s%s\n", $$1, $$2}'

install: ## Fetch pinned contracts and install locked JavaScript tools
	git submodule update --init --recursive
	npm ci --ignore-scripts

install-security: ## Install hash-locked Slither in a local Python 3.12 environment
	python3.12 -m venv .venv-security
	.venv-security/bin/python -m pip install --require-hashes -r requirements-security.txt

build: ## Compile and report sizes
	forge build --sizes

rebuild: clean build ## Clean then build

test: ## Run all Solidity tests
	forge test

test-ci: ## Run strict tests (50k fuzz; 1k invariants at depth 256)
	FOUNDRY_PROFILE=ci forge test -vvv

test-lite: ## Fast local test loop; not a release gate
	FOUNDRY_PROFILE=lite forge test

# Forge 1.5 coverage uses optimizer=false/runs=200. Exact-bytecode verifier
# tests need matching out/ artifacts, including metadata. Restore the normal
# build even if coverage fails; never weaken the verifier for instrumentation.
coverage: ## Generate line/branch coverage evidence
	@coverage_status=0; \
	FOUNDRY_PROFILE=default FOUNDRY_OPTIMIZER=false FOUNDRY_OPTIMIZER_RUNS=200 forge build --force && \
	FOUNDRY_PROFILE=default forge coverage --report lcov --report summary || coverage_status=$$?; \
	FOUNDRY_PROFILE=default forge build --force || exit $$?; \
	exit $$coverage_status

fmt: ## Format Solidity
	forge fmt

fmt-check: ## Check Solidity formatting
	forge fmt --check

solhint: ## Run locked Solhint
	./node_modules/.bin/solhint 'src/**/*.sol' 'script/**/*.sol'

slither: ## Analyze production and deployment scripts; fail at medium or higher
	FOUNDRY_PROFILE=default .venv-security/bin/slither . --config-file slither.config.json --foundry-compile-all --fail-medium

check-deps: ## Verify locked revisions and clean dependency worktrees
	./script/check-deps.sh

abi: ## Enforce the reviewed token function surface
	python3 script/check-abi.py

test-tools: ## Regression tests for the manifest, ABI gate, gas report and dependency tooling
	python3 -m unittest discover -s test/tools -p 'test_*.py'
	node --test test/script/*.test.mjs

lint: fmt-check solhint ## Format and lint

check: fmt-check solhint check-deps test-ci gas-check abi test-tools ## All main checks except separately installed Slither

release-check: check slither ## Full local release gate, including Slither

gas: ## Regenerate docs/GAS.md under the default profile
	node script/gas-report.mjs

gas-check: ## Reject stale generated gas evidence
	node script/gas-report.mjs --check

anvil: ## Start a local chain
	anvil

# Gas limits come from the target network's node. --skip-simulation makes Forge
# send each transaction with the node's eth_estimateGas result (x1.3) instead of
# a figure from its own simulation, whose gas rules can lag the network's: after
# the fork Sepolia activated on 6 October 2026, creating the token needs about
# 7.75M gas there against 1.14M in Forge's simulation. The script still runs
# locally against live state, with its pre-flight and post-deploy checks, before
# anything is sent, and a creation that would revert on the network fails its
# estimate and is not sent.
DEPLOY := forge script script/Deploy.s.sol --account deployer --broadcast --verify --skip-simulation

deploy-sepolia: ## Broadcast and explorer-verify on Sepolia
	$(DEPLOY) --rpc-url sepolia

deploy-hoodi: ## Broadcast and explorer-verify on Hoodi
	$(DEPLOY) --rpc-url hoodi

deploy-base-sepolia: ## Broadcast and explorer-verify on Base Sepolia
	$(DEPLOY) --rpc-url base_sepolia

deploy-mainnet: ## Broadcast Ethereum mainnet (requires CONFIRM=yes-deploy-nvnm-to-mainnet)
ifneq ($(CONFIRM),yes-deploy-nvnm-to-mainnet)
	@echo "REFUSING: set CONFIRM=yes-deploy-nvnm-to-mainnet after the launch review."
	@exit 1
endif
	I_UNDERSTAND_THIS_IS_MAINNET=true $(DEPLOY) --rpc-url mainnet --slow

deploy-base: ## Broadcast Base mainnet (requires CONFIRM=yes-deploy-nvnm-to-base)
ifneq ($(CONFIRM),yes-deploy-nvnm-to-base)
	@echo "REFUSING: set CONFIRM=yes-deploy-nvnm-to-base after the launch review."
	@exit 1
endif
	I_UNDERSTAND_THIS_IS_MAINNET=true $(DEPLOY) --rpc-url base --slow

verify: ## Compare live deployment with approved local build and EXPECTED_* inputs
	forge script script/VerifyDeployment.s.sol --rpc-url $(NETWORK)

clean: ## Remove generated build output
	forge clean
