RELEASE_DIR = dist/app

all:
	mkdir -p $(RELEASE_DIR)
	cabal build
	cp dist/build/eventsource-broker/eventsource-broker $(RELEASE_DIR)/eventsource-broker
	cp -r static $(RELEASE_DIR)
	cp -r templates $(RELEASE_DIR)
	cd dist &&  tar -czf eventsource-broker.tar.gz app/	
