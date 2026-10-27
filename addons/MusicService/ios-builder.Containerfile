FROM localhost/nari-macos-builder

COPY iPhoneOS26.5.sdk.zip /tmp/sdk/
RUN apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/* \
    && unzip -q /tmp/sdk/iPhoneOS26.5.sdk.zip -d /opt/ios-sdk && rm -rf /opt/ios-sdk/__MACOSX /tmp/sdk \
    && CARGO_HOME=/opt/cargo rustup target add aarch64-apple-ios \
    && chmod -R a+rX /opt/rustup /opt/cargo /opt/ios-sdk

ENV IOS_SDK=/opt/ios-sdk/iPhoneOS26.5.sdk
