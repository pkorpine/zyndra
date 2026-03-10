FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install Yocto Scarthgap build dependencies
RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect \
    xz-utils debianutils iputils-ping python3-git python3-jinja2 \
    libegl1-mesa libsdl2-dev pylint xterm python3-subunit \
    mesa-common-dev zstd liblz4-tool locales vim nano curl \
    file lz4 sudo libncurses6 libtinfo6 screen \
    gcc-multilib g++-multilib \
    libncurses5 libtinfo5 \
    dropbear-bin \
    && rm -rf /var/lib/apt/lists/*

# Set locale
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Create build user with matching host UID/GID (will be set at runtime)
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN groupadd -g ${GROUP_ID} builder && \
    useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER builder
WORKDIR /w

# Set git config
RUN git config --global user.email "builder@localhost" && \
    git config --global user.name "Builder"

# Configure bash history to persist in /w
RUN echo 'export HISTFILE=/w/.bash_history' >> /home/builder/.bashrc && \
    echo 'export HISTSIZE=10000' >> /home/builder/.bashrc && \
    echo 'export HISTFILESIZE=10000' >> /home/builder/.bashrc

COPY --chown=builder:builder entrypoint.sh /home/builder/entrypoint.sh
RUN chmod +x /home/builder/entrypoint.sh
ENTRYPOINT ["/home/builder/entrypoint.sh"]
CMD ["bash"]
