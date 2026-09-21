bin/pas: src/pas.swift
	swiftc -O src/pas.swift -o bin/pas

test: bin/pas
	./test/smoke.sh

.PHONY: test
