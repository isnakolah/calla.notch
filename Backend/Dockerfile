FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG REVISION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/calla-backend ./cmd/calla-backend

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/calla-backend /usr/local/bin/calla-backend
ENV CALLA_DATA_DIR=/data CALLA_LISTEN=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/calla-backend"]
CMD ["serve"]
