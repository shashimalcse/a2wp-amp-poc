# Wallet platform plus the dev issuer/verifier in one image, built from
# ../a2wp-wallet:  docker build -f Dockerfile -t a2wp-wallet:poc ../a2wp-wallet
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/ ./cmd/a2wp-walletd ./cmd/a2wp-devstack

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /
USER nonroot:nonroot
ENTRYPOINT ["/a2wp-walletd"]
CMD ["serve"]
