#!/usr/bin/env bash

# exit with error status on first failure
set -e

script_name="$(basename -- "$0")"

trap "echo 'Something went wrong! Tidying up...' && exit 1" ERR

help_text()
{
    echo ""
    echo "Usage:        ./$script_name COMMAND"
    echo ""
    echo "Helper script to run and manage the ancillary services that Eigen relies on."
    echo "Docker and Docker-compose are used to supply these services and run them as containers."
    echo ""
    echo "Available Commands:"
    echo "  build       Build the services"
    echo "  start       Start the services"
    echo "  stop        Stop the services"
    echo "  restart     Restart the services"
    echo "  status      Display the status of the running services for this project"
    echo "  clean       Stop and remove any containers related to this project which may have turned into zombies"
    echo "  nuke        Remove any docker volumes related to this project"
    echo "  teamcity    Print the 'setParameter' strings that TeamCity uses to set parameters in a build config"
}

# Helper function: Exit with error


check_required_env_variables()
{
	var_not_set() {
		echo "❌ Environment variable not set: $1" 1>&2
		exit 1
	}
    if [[ ! $AWS_DEFAULT_REGION || ! $AWS_ACCESS_KEY_ID || ! $AWS_SECRET_ACCESS_KEY ]]; then
        var_not_set "AWS_DEFAULT_REGION; AWS_ACCESS_KEY_ID; AWS_SECRET_ACCESS_KEY"
    fi
    if [[ ! $DOCKER_PASSWORD ]]; then
        var_not_set "DOCKER_PASSWORD"
    fi
}
set_common_env_variables()
{
	export DOCKER_USER=gbournique

	# CI/CD docker image
	export CICD_IMAGE_TAG=$(cat environment.yml poetry.lock | cksum | cut -c -8)
	export CICD_IMAGE_REPOSITORY=${DOCKER_USER}/cicd-with-deps

	# Webapp docker image
	WEBAPP_DEPENDENCIES_FILES=(\
		Dockerfile environment.yml poetry.lock \
		$(find ./app -type f -not -name "*.pyc" -not -name "*.log") \
	)
	CKSUM=$(cat ${WEBAPP_DEPENDENCIES_FILES} | cksum | cut -c -8)
	PROJECT_VERSION=$(awk '/^version/' pyproject.toml | sed 's/[^0-9\.]//g')
	export WEBAPP_IMAGE_TAG=${PROJECT_VERSION}-${CKSUM}
	export WEBAPP_IMAGE_REPOSITORY=${DOCKER_USER}/django-on-aws
	export WEBAPP_CONTAINER_NAME=webapp
	export DEBUG=False

	check_required_env_variables
}

docker-ci() {
	docker network create global-network 2>/dev/null || true; \
	docker run \
		-it --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v $(pwd):/root/cicd/ \
		--network global-network \
		-e AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION} \
		-e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
		-e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
		${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} bash -c "$*"
}

build_cicd_image() {
	printf "Building cicd docker image ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG}...\n"
	if docker manifest inspect ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} >/dev/null 2>&1; then \
		echo Docker image ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} already exists on Dockerhub! Not building.; \
		docker pull ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG}; \
	else \
		docker build -t ${CICD_IMAGE_REPOSITORY}:${CICD_IMAGE_TAG} -f .circleci/cicd.Dockerfile . ; \
	fi
}

build_webapp_image() {
	printf "Building webapp docker image ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG}...\n"
	if docker manifest inspect ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} >/dev/null 2>&1; then \
		echo Docker image ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} already exists on Dockerhub! Not building.; \
		docker pull ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG}; \
	else \
		docker build -t ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} . ; \
	fi
}

start_db()
{
	docker-ci docker-compose up -d || true
}

stop_db()
{
	docker-ci docker-compose down --remove-orphans >/dev/null 2>&1 || true
}

unit_tests()
{
	docker-ci "pytest app -x; coverage-badge -o .github/coverage.svg -f"
}

lint()
{
	docker-ci pre-commit run --all-files --show-diff-on-failure
}

up()
{
	docker-ci docker run -d --name webapp -p 8080:8080 --restart=no \
			  		 	 --network global-network \
						 --env DEBUG=True \
						 --env POSTGRES_HOST=postgres \
						 --env POSTGRES_PASSWORD=postgres \
						 --env REDIS_ENDPOINT=redis:6379 \
						 --env SNS_TOPIC_ARN= \
						 ${WEBAPP_IMAGE_REPOSITORY}:${WEBAPP_IMAGE_TAG} || true; \
}

down()
{
	docker-ci docker rm --force $(docker ps --filter name=${WEBAPP_CONTAINER_NAME} -qa) >/dev/null 2>&1
}


healthcheck()
{
	get_service_health() {
		echo "$1" | xargs -I ID docker inspect -f '{{if .State.Running}}{{ .State.Health.Status }}{{end}}' ID
	}

	container_id=$(docker ps --filter name=${WEBAPP_CONTAINER_NAME} -qa)

	# Check if container exists
	if [[ -z "${container_id}" ]]; then
		echo "❌ Container $1 is not running.. Aborting!"
		exit 1
	fi;

	# Wait for the container to fully start up
	until [[ $(get_service_health "${container_id}") != "starting" ]]; do
		sleep 1
	done;

	# Check if container status shows healthy
	if [[ $(get_service_health "${container_id}") != "healthy" ]]; then
		echo "❌ $1 failed health check"
		exit 1
	fi;

	echo "🍀 Container $1 running is healthy"
}

publish_image()
{
	echo ${DOCKER_PASSWORD} | docker login --username ${DOCKER_USER} --password-stdin 2>&1
	printf "Publishing $1:$2...\n"
	docker push $1:$2
	docker tag $1:$2 $1:latest
	docker push $1:latest
}

put_ssm_parameter_str()
{
	printf "Updating parameter '$1' with value '$2'\n"
	docker-ci aws ssm put-parameter \
				  --name $1 \
				  --value $2 \
				  --type "String" \
				  --overwrite >/dev/null; \
}


if [[ -n $1 ]]; then
	case "$1" in
		build_docker_images)
			printf "🔨  Building cicd and webapp docker images...\n"
			set_common_env_variables
			build_cicd_image
			build_webapp_image
			exit 0
			;;
		start_db)
			printf "🐳  Starting redis and postgres containers...\n"
			set_common_env_variables
			start_db
			exit 0
			;;
		up)
			printf "🐳  Starting webapp container...\n"
			set_common_env_variables
			start_db
			up
			exit 0
			;;
		unit_tests)
			printf "🔎🕵  Running unit tests...\n"
			set_common_env_variables
			start_db
			unit_tests
			stop_db
			exit 0
			;;
		lint)
			printf "🚨✨  Running pre-commit hooks (linting)...\n"
			set_common_env_variables
			lint
			exit 0
			;;
		healthcheck)
			printf "👨‍⚕🚑  Checking webapp container health...\n"
			set_common_env_variables
			start_db
			up
			healthcheck
			down
			stop_db
			exit 0
			;;
		stop_db)
			printf "🔥🚒  Stopping redis and postgres containers...\n"
			set_common_env_variables
			stop_db
			exit 0
			;;
		down)
			printf "🧹  Stopping and removing all containers...\n"
			set_common_env_variables
			stop_db
			down
			exit 0
			;;
		publish_images)
			printf "🐳 Publishing images to Dockerhub...\n"
			set_common_env_variables
			publish_image ${WEBAPP_IMAGE_REPOSITORY} ${WEBAPP_IMAGE_TAG}
			publish_image ${CICD_IMAGE_REPOSITORY} ${CICD_IMAGE_TAG}
			exit 0
			;;
		put_ssm_parameters)
			printf "☁️  Updating AWS ssm parameters...\n"
			set_common_env_variables
			put_ssm_parameter_str "/CODEDEPLOY/DOCKER_IMAGE_NAME_DEMO" "${WEBAPP_IMAGE_REPOSITORY}:latest"
			put_ssm_parameter_str "/CODEDEPLOY/DEBUG_DEMO" "${DEBUG}"
			exit 0
			;;
		run_ci)
			printf "🚀  Running CI pipeline steps (for local troubleshooting)...\n"
			set_common_env_variables
			build_cicd_image
			build_webapp_image
			start_db
			unit_tests
			lint
			up
			healthcheck
			down
			stop_db
			publish_image ${WEBAPP_IMAGE_REPOSITORY} ${WEBAPP_IMAGE_TAG}
			publish_image ${CICD_IMAGE_REPOSITORY} ${CICD_IMAGE_TAG}
			put_ssm_parameters
			clean
			exit 0
			;;
		*)
			echo "¯\\_(ツ)_/¯ What do you mean \"$1\"?"
			help_text
			exit 1
			;;
	esac
else
	help_text
	exit 1
fi