ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR := $(ROOT_DIR)/build
DIST_DIR := $(BUILD_DIR)/dist
GIT_COMMIT := $(shell git rev-parse HEAD)

S3_BUCKET ?= infinity-artifacts
# Default to putting artifacts under a random directory, which will get cleaned up automatically:
S3_PREFIX ?= autodelete7d/spark/test-`date +%Y%m%d-%H%M%S`-`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1`
SPARK_REPO_URL ?= https://github.com/mesosphere/spark

.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS = -ec

# This image can be used to build spark dist and run tests
DOCKER_BUILD_IMAGE ?= mesosphere/spark-build:$(GIT_COMMIT)
docker-build:
	docker build -t $(DOCKER_BUILD_IMAGE) .
	echo $(DOCKER_BUILD_IMAGE) > $@

# Pulls the spark distribution listed in the manifest as default
SPARK_DIST_URI ?= $(shell jq ".default_spark_dist.uri" "$(ROOT_DIR)/manifest.json")
manifest-dist:
	mkdir -p $(DIST_DIR)
	pushd $(DIST_DIR)
	wget $(SPARK_DIST_URI)
	popd

HADOOP_VERSION ?= $(shell jq ".default_spark_dist.hadoop_version" "$(ROOT_DIR)/manifest.json")

SPARK_DIR ?= $(ROOT_DIR)/spark
$(SPARK_DIR):
	git clone $(SPARK_REPO_URL) $(SPARK_DIR)

# Builds a quick dev version of spark from the mesosphere fork
dev-dist: $(SPARK_DIR)
	cd $(SPARK_DIR)
	rm -rf spark-*.tgz
	build/sbt -Pmesos "-Phadoop-$(HADOOP_VERSION)" -Phive -Phive-thriftserver package
	rm -rf /tmp/spark-SNAPSHOT*
	mkdir -p /tmp/spark-SNAPSHOT/jars
	cp -r assembly/target/scala*/jars/* /tmp/spark-SNAPSHOT/jars
	mkdir -p /tmp/spark-SNAPSHOT/examples/jars
	cp -r examples/target/scala*/jars/* /tmp/spark-SNAPSHOT/examples/jars
	for f in /tmp/spark-SNAPSHOT/examples/jars/*; do \
		name=$$(basename "$$f"); \
		if [ -f "/tmp/spark-SNAPSHOT/jars/$${name}" ]; then \
			rm "/tmp/spark-SNAPSHOT/examples/jars/$${name}"; \
		fi; \
	done; \
	cp -r data /tmp/spark-SNAPSHOT/
	mkdir -p /tmp/spark-SNAPSHOT/conf
	cp conf/* /tmp/spark-SNAPSHOT/conf
	cp -r bin /tmp/spark-SNAPSHOT
	cp -r sbin /tmp/spark-SNAPSHOT
	cp -r python /tmp/spark-SNAPSHOT
	cd /tmp
	tar czf spark-SNAPSHOT.tgz spark-SNAPSHOT
	mkdir -p $(DIST_DIR)
	cp /tmp/spark-SNAPSHOT.tgz $(DIST_DIR)/

prod-dist: $(SPARK_DIR)
	cd $(SPARK_DIR)
	rm -rf spark-*.tgz
	if [ -f make-distribution.sh ]; then \
		./make-distribution.sh --tgz "-Phadoop-$(HADOOP_VERSION)" -Phive -Phive-thriftserver -DskipTests; \
	else \
		if [ -n $(does_profile_exist,mesos) ]; then \
			MESOS_PROFILE="-Pmesos"; \
		else \
			MESOS_PROFILE=""; \
		fi; \
		./dev/make-distribution.sh --tgz "$${MESOS_PROFILE}" "-Phadoop-$(HADOOP_VERSION)" -Pnetlib-lgpl -Psparkr -Phive -Phive-thriftserver -DskipTests; \
	fi; \
	mkdir -p $(DIST_DIR)
	cp spark-*.tgz $(DIST_DIR)

# this target serves as default dist type
$(DIST_DIR):
	$(MAKE) manifest-dist

clean-dist:
	@[ ! -e $(DIST_DIR) ] || rm -rf $(DIST_DIR)

docker-login:
	docker login --email="$(DOCKER_EMAIL)" --username="$(DOCKER_USERNAME)" --password="$(DOCKER_PASSWORD)"

DOCKER_DIST_IMAGE ?= mesosphere/spark-dev:$(GIT_COMMIT)
docker-dist: $(DIST_DIR)
	tar xvf $(DIST_DIR)/spark-*.tgz -C $(DIST_DIR)
	rm -rf $(BUILD_DIR)/docker
	mkdir -p $(BUILD_DIR)/docker/dist
	cp -r $(DIST_DIR)/spark-*/. $(BUILD_DIR)/docker/dist
	cp -r conf/* $(BUILD_DIR)/docker/dist/conf
	cp -r docker/* $(BUILD_DIR)/docker
	pushd $(BUILD_DIR)/docker; \
	docker build -t $(DOCKER_DIST_IMAGE) .; \
	popd
	docker push $(DOCKER_DIST_IMAGE)
	echo "$(DOCKER_DIST_IMAGE)" > $@


cli:
	$(ROOT_DIR)/cli/build.sh


UNIVERSE_URL_PATH ?= $(ROOT_DIR)/stub-universe-url
stub-universe: docker-dist cli
	@if [ -n "$(STUB_UNIVERSE_URL)" ]; then
		echo "Using provided Spark stub universe: $(STUB_UNIVERSE_URL)"
		echo "$(STUB_UNIVERSE_URL)" > $(UNIVERSE_URL_PATH)
	else
		UNIVERSE_URL_PATH=$(ROOT_DIR)/stub-universe-url.spark \
		TEMPLATE_HTTPS_PROTOCOL='https://' \
		TEMPLATE_DOCKER_IMAGE=`cat docker-dist` \
			$(ROOT_DIR)/tools/build_package.sh \
			spark \
			$(ROOT_DIR) \
			-a $(ROOT_DIR)/cli/dcos-spark-darwin \
			-a $(ROOT_DIR)/cli/dcos-spark-linux \
			-a $(ROOT_DIR)/cli/dcos-spark.exe \
			aws
		cat $(ROOT_DIR)/stub-universe-url.spark > $(UNIVERSE_URL_PATH)
	fi
	@if [ -n "$(HISTORY_STUB_UNIVERSE_URL)" ]; then
		echo "Using provided History stub universe: $(HISTORY_STUB_UNIVERSE_URL)"
		echo "$(HISTORY_STUB_UNIVERSE_URL)" >> $(UNIVERSE_URL_PATH)
	else
		UNIVERSE_URL_PATH=$(ROOT_DIR)/stub-universe-url.history \
		DOCKER_IMAGE=`cat docker-dist` \
		TEMPLATE_DEFAULT_DOCKER_IMAGE=${DOCKER_IMAGE} \
		TEMPLATE_HTTPS_PROTOCOL='https://' \
		        $(ROOT_DIR)/tools/build_package.sh spark-history $(ROOT_DIR)/history aws
		cat $(ROOT_DIR)/stub-universe-url.history >> $(UNIVERSE_URL_PATH)
	fi


DCOS_SPARK_TEST_JAR_PATH ?= $(ROOT_DIR)/dcos-spark-scala-tests-assembly-0.1-SNAPSHOT.jar
$(DCOS_SPARK_TEST_JAR_PATH):
	cd tests/jobs/scala
	sbt assembly
	cp $(ROOT_DIR)/tests/jobs/scala/target/scala-2.11/dcos-spark-scala-tests-assembly-0.1-SNAPSHOT.jar $(DCOS_SPARK_TEST_JAR_PATH)

CF_TEMPLATE_URL ?= https://s3.amazonaws.com/downloads.mesosphere.io/dcos-enterprise/testing/master/cloudformation/ee.single-master.cloudformation.json
config.yaml:
	$(eval export DCOS_LAUNCH_CONFIG_BODY)
	echo "$$DCOS_LAUNCH_CONFIG_BODY" > config.yaml

cluster-url: config.yaml
	@if [ -n $(CLUSTER_URL) ]; then
		echo "Using provided CLUSTER_URL: $(CLUSTER_URL)"
		echo "$(CLUSTER_URL)" > $@
	else
		echo "Launching new cluster (no CLUSTER_URL provided)"
		dcos-launch create
		dcos-launch wait
		echo https://`dcos-launch describe | jq -r .masters[0].public_ip` > $@
	fi

clean-cluster:
	@if [ -n $(CLUSTER_URL) ]; then
		echo "Not deleting cluster provided by external CLUSTER_URL: $(CLUSTER_URL)"
	else
		dcos-launch delete || echo "Error deleting cluster"
	fi

mesos-spark-integration-tests:
	git clone https://github.com/typesafehub/mesos-spark-integration-tests $(ROOT_DIR)/mesos-spark-integration-tests

MESOS_SPARK_TEST_JAR_PATH ?= $(ROOT_DIR)/mesos-spark-integration-tests-assembly-0.1.0.jar
$(MESOS_SPARK_TEST_JAR_PATH): mesos-spark-integration-tests
	cd $(ROOT_DIR)/mesos-spark-integration-tests/test-runner
	sbt assembly
	cd ..
	sbt clean compile test
	cp test-runner/target/scala-2.11/mesos-spark-integration-tests-assembly-0.1.0.jar $(MESOS_SPARK_TEST_JAR_PATH)

test: $(DCOS_SPARK_TEST_JAR_PATH) $(MESOS_SPARK_TEST_JAR_PATH) stub-universe cluster-url
	if [ -z $(CLUSTER_URL) ]; then
		if [ `cat cluster_info.json | jq .key_helper` == 'true' ]; then
			cat cluster_info.json | jq -r .ssh_private_key > test_cluster_ssh_key
			chmod 600 test_cluster_ssh_key
			eval `ssh-agent -s`
			ssh-add test_cluster_ssh_key
		fi
	fi
	CLUSTER_URL=`cat $(ROOT_DIR)/cluster-url` \
	STUB_UNIVERSE_URL=`cat $(UNIVERSE_URL_PATH)` \
	CUSTOM_DOCKER_ARGS="-e DCOS_SPARK_TEST_JAR_PATH=/build/`basename ${DCOS_SPARK_TEST_JAR_PATH}` -e MESOS_SPARK_TEST_JAR_PATH=/build/`basename ${MESOS_SPARK_TEST_JAR_PATH}` -e S3_PREFIX=$(S3_PREFIX) -e S3_BUCKET=$(S3_BUCKET)" \
	S3_BUCKET=$(S3_BUCKET) \
		$(ROOT_DIR)/test.sh -m nick

clean: clean-cluster
	for f in  "$(MESOS_SPARK_TEST_JAR_PATH)" "$(DCOS_SPARK_TEST_JAR_PATH)" "$(UNIVERSE_URL_PATH)" "$(HISTORY_URL_PATH)" "docker-build" "docker-dist" ; do
		[ ! -e $$f ] || rm $$f
	done



define spark_dist
`cd $(DIST_DIR) && ls spark-*.tgz`
endef

define does_profile_exist
`cd "$(SPARK_DIR)" && ./build/mvn help:all-profiles | grep $(1)`
endef


define DCOS_LAUNCH_CONFIG_BODY
---
launch_config_version: 1
deployment_name: dcos-ci-test-spark-build-$(shell cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 10 | head -n 1)
template_url: $(CF_TEMPLATE_URL)
provider: aws
key_helper: true
template_parameters:
  AdminLocation: 0.0.0.0/0
  PublicSlaveInstanceCount: 1
  SlaveInstanceCount: 5
ssh_user: core
endef


.PHONY: clean clean-dist cluster-url clean-cluster cli stub-universe manifest-dist dev-dist prod-dist docker-login test
