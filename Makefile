.PHONY: build test vet workflow-test check benchmark benchmark-samples assess profile profile-cpu profile-alloc

PROFILE_SCENARIO ?= Balanced

build:
	go build ./...

test:
	go test ./...

vet:
	go vet ./...

workflow-test:
	bash scripts/derive-candidate-base-test.sh
	bash scripts/dispatch-private-evaluator-test.sh

check: vet test build workflow-test

benchmark:
	GOMAXPROCS=1 go test -run '^$$' -bench . -benchmem -benchtime=250ms -cpu=1 ./internal/assessment

benchmark-samples:
	mkdir -p .bench
	GOMAXPROCS=1 go test -run '^$$' -bench . -benchmem -benchtime=500ms -count=7 -cpu=1 ./internal/assessment | tee .bench/current.txt

assess:
	@if [ -z "$${BASELINE_CHECKOUT:-}" ] || \
	    [ -z "$${CANDIDATE_CHECKOUT:-}" ] || \
	    [ -z "$${BASELINE_SHA:-}" ] || \
	    [ -z "$${CANDIDATE_BASE_SHA:-}" ] || \
	    [ -z "$${CANDIDATE_SHA:-}" ] || \
	    [ -z "$${ASSESS_OUTPUT:-}" ] || \
	    [ -z "$${ASSESSMENT_DOCKER_IMAGE:-}" ]; then \
		echo 'usage: BASELINE_CHECKOUT=/clean/baseline CANDIDATE_CHECKOUT=/clean/candidate BASELINE_SHA=<pinned-40sha> CANDIDATE_BASE_SHA=<pr-base-40sha> CANDIDATE_SHA=<candidate-40sha> ASSESS_OUTPUT=/new/output ASSESSMENT_DOCKER_IMAGE=name@sha256:<digest> make assess' >&2; \
		exit 2; \
	fi
	@bash scripts/assess.sh \
		"$$BASELINE_CHECKOUT" \
		"$$CANDIDATE_CHECKOUT" \
		"$$BASELINE_SHA" \
		"$$CANDIDATE_BASE_SHA" \
		"$$CANDIDATE_SHA" \
		"$$ASSESS_OUTPUT"

profile:
	bash scripts/profile.sh all "$(PROFILE_SCENARIO)"

profile-cpu:
	bash scripts/profile.sh cpu "$(PROFILE_SCENARIO)"

profile-alloc:
	bash scripts/profile.sh alloc "$(PROFILE_SCENARIO)"
