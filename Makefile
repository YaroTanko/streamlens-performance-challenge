.PHONY: build test vet check benchmark benchmark-samples

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
