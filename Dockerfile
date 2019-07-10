#--------------------------#
# Dependencies and Linting #
#--------------------------#
FROM debian:buster-slim AS dependencies

RUN apt-get update                                                               \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates                                                              \
    curl                                                                         \
    shellcheck                                                                   \
    unzip

# Install terraform
# TODO: (rem) use `terraform-bundle`
ENV TERRAFORM_VERSION 0.12.3
RUN curl -sLO                                                                                                      \
      https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip                                                        \
    && mv terraform /usr/local/bin/

# Install JQ
ENV JQ_VERSION 1.6
RUN curl -sL https://github.com/stedolan/jq/releases/download/jq-${JQ_VERSION}/jq-linux64 \
      -o /usr/local/bin/jq                                                                \
    && chmod +x /usr/local/bin/jq

## Install YQ
ENV YQ_VERSION 2.7.2
RUN curl -sL https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64 \
      -o /usr/local/bin/yq                                                                  \
    && chmod +x /usr/local/bin/yq

## Install Goss
ENV GOSS_VERSION v0.3.7
RUN curl -sL https://github.com/aelsabbahy/goss/releases/download/${GOSS_VERSION}/goss-linux-amd64 \
         -o /usr/local/bin/goss                                                                    \
    && chmod +rx /usr/local/bin/goss

# Install Hadolint
ENV HADOLINT_VERSION v1.16.3
RUN curl -sL https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64 \
        -o /usr/local/bin/hadolint                                                                            \
    && chmod +x /usr/local/bin/hadolint

# Setup non-root lint user
ARG lint_user=lint
RUN useradd -ms /bin/bash ${lint_user} \
    && mkdir /app

WORKDIR /app

# Copy Dockerfiles, hadolint config and scripts
COPY --chown=1000 Dockerfile .hadolint.yaml ./
COPY --chown=1000 scripts/ ./scripts/
COPY --chown=1000 attack/ ./attack/

USER ${lint_user}

RUN ls -lasph

# Lint Dockerfiles
RUN hadolint Dockerfile            \
    &&  hadolint attack/Dockerfile \
# Lint shell scripts
    && shellcheck scripts/*        \
    && shellcheck attack/scripts/*

#-----------------------#
# Golang Build and Test #
#-----------------------#
FROM debian:buster-slim AS build-and-test

RUN apt-get update                                                               \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential                                                              \
    ca-certificates                                                              \
    git                                                                          \
    golang                                                                       \
    unzip

COPY --from=dependencies /usr/local/bin/terraform /usr/local/bin/terraform

# Setup non-root build user
ARG build_user=build
RUN useradd -ms /bin/bash ${build_user}

# Create golang src directory
RUN mkdir -p /go/src/github.com/controlplaneio/simulator-standalone

# Create an empty public ssh key file for the tests
RUN mkdir -p /home/${build_user}/.ssh && echo  "ssh-rsa FOR TESTING" > /home/${build_user}/.ssh/id_rsa.pub \
# Create module cache and copy manifest files
    &&  mkdir -p /home/${build_user}/go/pkg/mod
COPY ./go.* /go/src/github.com/controlplaneio/simulator-standalone/

# Give ownership of module cache and src tree to build user
RUN chown -R ${build_user}:${build_user} /go/src/github.com/controlplaneio/simulator-standalone \
    && chown -R ${build_user}:${build_user} /home/${build_user}/go

# Run all build and test steps as build user
USER ${build_user}

# Install golang module dependencies before copying source to cache them in their own layer
WORKDIR /go/src/github.com/controlplaneio/simulator-standalone
RUN go mod download

# Add the full source tree
COPY --chown=1000 .  /go/src/github.com/controlplaneio/simulator-standalone/
WORKDIR /go/src/github.com/controlplaneio/simulator-standalone/

# TODO: (rem) why is this owned by root after the earlier chmod?
USER root
RUN chown -R ${build_user}:${build_user} /go/src/github.com/controlplaneio/simulator-standalone/

USER ${build_user}

# Golang build and test
WORKDIR /go/src/github.com/controlplaneio/simulator-standalone
ENV GO111MODULE=on
RUN make test

#------------------#
# Launch Container #
#------------------#
FROM debian:buster-slim

RUN apt update                                                               \
    && DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
    awscli                                                                   \
    bash                                                                     \
    bzip2                                                                    \
    ca-certificates                                                          \
    curl                                                                     \
    file                                                                     \
    gettext-base                                                             \
    gnupg                                                                    \
    golang                                                                   \
    lsb-release                                                              \
    make                                                                     \
    openssh-client                                                           \
 && rm -rf /var/lib/apt/lists/*

# Add login message
COPY --from=build-and-test /go/src/github.com/controlplaneio/simulator-standalone/scripts/launch-motd /usr/local/bin/launch-motd
RUN echo '[ ! -z "$TERM" ] && launch-motd' >> /etc/bash.bashrc

# Use 3rd party dependencies from build
COPY --from=dependencies /usr/local/bin/jq /usr/local/bin/jq
COPY --from=dependencies /usr/local/bin/yq /usr/local/bin/yq
COPY --from=dependencies /usr/local/bin/goss /usr/local/bin/goss
COPY --from=dependencies /usr/local/bin/terraform /usr/local/bin/terraform

# Copy statically linked simulator binary
COPY --from=build-and-test /go/src/github.com/controlplaneio/simulator-standalone/dist/simulator /usr/local/bin/simulator

# Setup non-root launch user
ARG launch_user=launch
RUN useradd -ms /bin/bash ${launch_user} \
    && mkdir /app                        \
    && chown -R ${launch_user}:${launch_user} /app

WORKDIR /app

# Add terraform and perturb/scenario scripts to the image and goss.yaml to verify the container
ARG config_file=./simulator.yaml
COPY --chown=1000 ./terraform/ ./terraform/
COPY --chown=1000 ./simulation-scripts/ ./simulation-scripts/
COPY --chown=1000 ./goss.yaml ${config_file} ./

ENV SIMULATOR_SCENARIOS_DIR=/app/simulation-scripts/ \
    SIMULATOR_TF_DIR=/app/terraform/deployments/AWS

USER ${launch_user}

CMD [ "/bin/bash" ]
