# URL shortener on AWS Lambda Web Functions

A URL shortener that runs as a single **AWS Lambda Web Function**, deployed with nothing but the
AWS CLI, on AWS and on LocalStack.

| Key          | Value                                                        |
| ------------ | ------------------------------------------------------------ |
| Environment  | LocalStack, AWS                                              |
| Services     | Lambda Web Functions, DynamoDB, S3, IAM, CloudWatch Logs     |
| Integrations | AWS CLI, `lstk`                                              |
| Categories   | Serverless, Web applications                                 |
| Level        | Beginner                                                     |

## Introduction

Lambda Web Functions run a plain HTTP server inside Lambda-managed execution environments and put a
managed HTTPS domain in front of it. There is no event/handler shape, no API Gateway and no adapter:
the same `app.listen()` that runs on a laptop runs in the cloud, and each environment serves many
requests concurrently.

This sample is an Express application that shortens URLs. Links live in a DynamoDB table with an
atomic click counter, a QR code for each link is generated on creation and stored in S3, and a small
UI is served by the same process. The whole thing is one Web Function with one endpoint.

## Architecture

- **Lambda Web Function** (`nodejs24.x`) running an Express server, with one `HomeRegion` endpoint
  using application-managed authentication and latest-revision auto-deployment.
- **DynamoDB** table `short-links` (partition key `slug`): target URL, creation time, click count.
- **S3** bucket for the QR code PNGs, plus a versioned bucket that holds the deployment package.
- **IAM** execution role scoped to the table, the QR bucket and the function's CloudWatch log groups.

| Method & path | Behaviour |
|---|---|
| `GET /` | the UI |
| `GET /healthz` | region, endpoint name, platform request id |
| `POST /api/links` `{url, slug?}` | create a link (`201`), `409` if the slug exists, `400` on a bad URL |
| `GET /api/links` | newest 50 links |
| `GET /api/links/:slug` | one link with its click count |
| `GET /api/links/:slug/qr.png` | the QR code, streamed from S3 |
| `GET /:slug` | `302` to the target, click counter incremented atomically |

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) with the
  `lambda-web` service model
- [`lstk`](https://docs.localstack.cloud/aws/developer-tools/running-localstack/lstk/), installed via
  `npm install -g @localstack/lstk` or `brew install localstack/tap/lstk`, and a
  [LocalStack Auth Token](https://docs.localstack.cloud/aws/getting-started/auth-token/)
- [Node.js](https://nodejs.org/en/download/) 24 and npm. The Web Function runtime ships no AWS SDK,
  so the deployment package carries `@aws-sdk/*` itself.
- `zip`, `curl`, `python3`

## Layout

```
app/
  index.js            Express app: routes, DynamoDB + S3 clients, structured request log
  public/index.html   the UI
  package.json        express, @aws-sdk/client-dynamodb, @aws-sdk/lib-dynamodb, @aws-sdk/client-s3, qrcode
scripts/
  deploy.sh           create buckets, table, role; package; upload; create-web-function; wait; smoke test
  cleanup.sh          remove everything, including S3 object versions and the two log groups
  *.template.json     bucket policy and role policy, filled in by deploy.sh
  *.localstack.json   the same two policies with LocalStack's account id and the names used in the LocalStack walkthrough
  endpoint-config.json, trust-policy.json
```

## Deploy on LocalStack

Start LocalStack for AWS, then run the deploy script with every AWS CLI call proxied through
`lstk aws`:

```bash
lstk start
AWS_CLI="lstk aws" ./scripts/deploy.sh
```

The script creates the supporting resources, packages the application, uploads it to a versioned
bucket, creates the Web Function with its first revision and a public endpoint in a single call,
waits for both to become `Active`, and prints the endpoint:

```
==> Live at http://<label>-lambda-web-us-east-1.localhost.localstack.cloud:4566/
HTTP/1.1 200 OK
lambda-web-logstream: 2026/09/29/lambda-web-shortener[rev-0y0jn]1c8869f966cd4e81954a7fc807d7d7d8
lambda-web-request-id: BTY5KAKPBZ52CBUP5L6G36SNJM
{"ok":true,"region":"us-east-1","endpoint":"public","requestId":"BTY5KAKPBZ52CBUP5L6G36SNJM","uptimeSeconds":1}
```

Open that URL in a browser for the UI, or use the API:

```bash
D=http://<label>-lambda-web-us-east-1.localhost.localstack.cloud:4566
curl -X POST $D/api/links -H 'content-type: application/json' -d '{"url":"https://docs.localstack.cloud/","slug":"ls-docs"}'
curl -i $D/ls-docs                      # 302 with a Location header, and the click is counted
curl $D/api/links/ls-docs
curl -o qr.png $D/api/links/ls-docs/qr.png
```

Each revision runs in a `node:24-slim` container with the same 2 vCPU / 2 GiB / 1,024
file-descriptor contract as AWS. LocalStack hands the sandbox `AWS_ENDPOINT_URL`, which the AWS SDK
honours, so the DynamoDB and S3 calls need no changes.

## Deploy on AWS

```bash
export AWS_PROFILE=<profile> AWS_DEFAULT_REGION=us-east-1
./scripts/deploy.sh
```

The endpoint domain is `https://<id>.<shard>.lambda-web.us-east-1.on.aws`.

## Clean up

```bash
AWS_CLI="lstk aws" ./scripts/cleanup.sh   # LocalStack
./scripts/cleanup.sh                      # AWS, same environment as deploy.sh
```

## Things worth knowing about Web Functions

- **Listen where you are told.** `AWS_LAMBDA_HTTP_ENDPOINT` is `host:port` (`0.0.0.0:3000`).
  Binding anywhere else fails initialization.
- **Code comes only from a versioned S3 bucket**, and every revision is pinned to an object
  version. Deleting that version later fails the revision permanently.
- **Revisions are immutable**; any config change is a new revision. Endpoints route traffic across
  at most two revisions with weights that must sum to 100.
- **The runtime ships no AWS SDK.** Bundle `@aws-sdk/*` in the zip.
- **Lambda strips `X-Forwarded-Proto`** and terminates TLS, so an app that builds absolute URLs
  has to decide the scheme itself (see `baseUrl()` in `app/index.js`).
- **Logs are JSON envelopes.** Application lines written during a request are stamped with
  `requestId` and `endpointName`.
- **Metrics are sparse.** `HTTPResponseStatusClass5XX` is simply absent when there were no errors;
  alarms need `--treat-missing-data notBreaching`.

## License

This code is available under the Apache 2.0 license.
