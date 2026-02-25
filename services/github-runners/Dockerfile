FROM ubuntu:24.04

ARG RUNNER_VERSION="2.331.0"
ARG DEBIAN_FRONTEND=noninteractive

# Update base system
RUN apt-get update && apt-get upgrade -y

# Create runner user
RUN useradd -m docker

# Install base tools (Ubuntu 24.04 ships git 2.43 — supports partial clone natively)
RUN apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    unzip \
    jq \
    ssh \
    ca-certificates \
    gnupg \
    lsb-release \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-venv \
    python3-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI + Buildx plugin (for docker/build-push-action)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 (for ECS deployment)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Install GitHub Actions runner
RUN cd /home/docker && mkdir actions-runner && cd actions-runner \
    && curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L \
       https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Set ownership and install runner dependencies
RUN chown -R docker /home/docker \
    && /home/docker/actions-runner/bin/installdependencies.sh

# Add docker user to the docker group so it can access the socket
RUN groupadd -f docker-host && usermod -aG docker-host docker

COPY --chmod=+x start.sh /start.sh

USER docker

ENTRYPOINT ["/start.sh"]
