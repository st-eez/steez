.PHONY: install build clean

build:
	go build -o steez ./cmd/steez

install:
	go install ./cmd/steez

clean:
	rm -f steez
