# MT5 in the browser (KasmVNC) with Wine pinned to a version MetaTrader accepts.
# Newer Wine (10.3+) triggers MT5's "A debugger has been found running in your system".
FROM gmag11/metatrader5_vnc:latest
ARG WINE_SERIES=9.0
RUN mkdir -pm755 /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && apt-get update \
 && echo "Available winehq-stable versions:" && apt-cache madison winehq-stable | awk '{print $3}' | head -20 \
 && V=$(apt-cache madison winehq-stable | awk '{print $3}' | grep -E "^${WINE_SERIES}\." | head -1) \
 && [ -n "$V" ] || (echo "No winehq-stable ${WINE_SERIES}.x found" && exit 1) \
 && V=$(apt-cache madison winehq-stable | awk '{print $3}' | grep -E "^${WINE_SERIES}\." | head -1) \
 && apt-get install -y --allow-downgrades winehq-stable=$V wine-stable=$V wine-stable-amd64=$V wine-stable-i386=$V \
 && apt-mark hold winehq-stable wine-stable wine-stable-amd64 wine-stable-i386 \
 && wine --version \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
