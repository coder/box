# Stage 1: pull 32-bit x86 shared libraries needed by the ADT tools (aapt, etc.)
FROM --platform=linux/386 debian:bookworm-slim AS i386-sysroot
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: native AMD64 JVM for fast compilation + x86/x86_64 ADT tools via binfmt QEMU
FROM eclipse-temurin:8-jdk

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    git \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Copy 32-bit x86 ELF loader + libraries so qemu-i386 can load dynamically-linked ADT binaries
COPY --from=i386-sysroot /lib/i386-linux-gnu/          /lib/i386-linux-gnu/
COPY --from=i386-sysroot /lib/ld-linux.so.2            /lib/ld-linux.so.2
COPY --from=i386-sysroot /usr/lib/i386-linux-gnu/      /usr/lib/i386-linux-gnu/

# Download and extract the legacy Android ADT bundle (2014, x86/x86_64 tools).
# Binaries execute transparently via the host qemu-i386 / qemu-x86_64 binfmt (F flag).
RUN mkdir -p /opt/adt && \
    curl -fL "http://dl.google.com/android/adt/adt-bundle-linux-x86_64-20140702.zip" \
         -o /tmp/adt.zip && \
    unzip -q /tmp/adt.zip -d /opt/adt && \
    rm /tmp/adt.zip && \
    find /opt/adt -type f \( -name "*.sh" -o -name "ant" -o -name "adb" \
         -o -name "aapt" -o -name "dx" -o -name "aidl" -o -name "android" \
         -o -name "mksdcard" -o -name "zipalign" \) -exec chmod +x {} + && \
    chmod -R a+x /opt/adt/adt-bundle-linux-x86_64-20140702/eclipse/plugins/org.apache.ant_1.8.3.v201301120609/bin/ || true

# Symlink java/javac/jar to a standard PATH location so subprocesses (dx, ant) can always find them
RUN ln -sf /opt/java/openjdk/bin/java  /usr/local/bin/java && \
    ln -sf /opt/java/openjdk/bin/javac /usr/local/bin/javac && \
    ln -sf /opt/java/openjdk/bin/jar   /usr/local/bin/jar

# Create a non-root coder user (uid/gid 1000) matching the convention used by other templates.
# eclipse-temurin:8-jdk already has an 'ubuntu' user at uid/gid 1000 — rename it to 'coder'.
# Grant passwordless sudo so workshop participants can install packages or run adb as needed.
RUN usermod -l coder -d /home/coder -m ubuntu && \
    groupmod -n coder ubuntu && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder && \
    chmod 0440 /etc/sudoers.d/coder && \
    chown -R coder:coder /opt/adt

ENV ANDROID_HOME=/opt/adt/adt-bundle-linux-x86_64-20140702/sdk
ENV ANT=/opt/adt/adt-bundle-linux-x86_64-20140702/eclipse/plugins/org.apache.ant_1.8.3.v201301120609/bin/ant
ENV PATH="/home/coder/.local/bin:${ANDROID_HOME}/tools:${ANDROID_HOME}/platform-tools:/opt/java/openjdk/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"

USER coder
WORKDIR /home/coder
