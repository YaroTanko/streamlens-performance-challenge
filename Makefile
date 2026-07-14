.PHONY: build test vet check benchmark benchmark-samples profile profile-cpu profile-alloc

PROFILE_SCENARIO ?= Balanced

build:
	go build ./...

test:
	go test ./...

vet:
	go vet ./...

check: vet test build

benchmark:
	GOMAXPROCS=1 go test -run '^$$' -bench . -benchmem -benchtime=250ms -cpu=1 ./internal/assessment

benchmark-samples:
	mkdir -p .bench
	GOMAXPROCS=1 go test -run '^$$' -bench . -benchmem -benchtime=500ms -count=7 -cpu=1 ./internal/assessment | tee .bench/current.txt

profile:
	bash scripts/profile.sh all "$(PROFILE_SCENARIO)"

profile-cpu:
	bash scripts/profile.sh cpu "$(PROFILE_SCENARIO)"

profile-alloc:
	bash scripts/profile.sh alloc "$(PROFILE_SCENARIO)"
