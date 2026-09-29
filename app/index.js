// A URL shortener running as an AWS Lambda Web Function.
//
// The whole application is an ordinary Express server. Lambda tells it where to listen through
// AWS_LAMBDA_HTTP_ENDPOINT, hands it the execution role's credentials in the environment, and
// forwards every HTTPS request from the endpoint domain to it over HTTP/1.1.
//
//   DynamoDB  short-links table  one item per slug: target url, created time, click counter
//   S3        qr bucket          one PNG per slug, generated when the link is created

const crypto = require("node:crypto");
const path = require("node:path");
const express = require("express");
const QRCode = require("qrcode");
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  ScanCommand,
  UpdateCommand,
} = require("@aws-sdk/lib-dynamodb");
const { GetObjectCommand, PutObjectCommand, S3Client } = require("@aws-sdk/client-s3");

const TABLE = process.env.LINKS_TABLE || "short-links";
const BUCKET = process.env.QR_BUCKET;
if (!BUCKET) throw new Error("QR_BUCKET environment variable is required");

// The SDK picks region and credentials up from the environment Lambda provides. On LocalStack the
// sandbox also receives AWS_ENDPOINT_URL, which the SDK honours; path-style addressing keeps S3
// requests on that single endpoint instead of a per-bucket hostname.
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({ forcePathStyle: Boolean(process.env.AWS_ENDPOINT_URL) });

const SLUG_PATTERN = /^[A-Za-z0-9_-]{3,32}$/;
const ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const randomSlug = () =>
  Array.from(crypto.randomBytes(7), (byte) => ALPHABET[byte % ALPHABET.length]).join("");

// Lambda terminates TLS and strips X-Forwarded-Proto, so the scheme is decided by where we are:
// endpoint domains are HTTPS only, LocalStack's gateway is plain HTTP on its port.
const baseUrl = (req) => {
  const host = req.get("host");
  const scheme = host && host.endsWith(".on.aws") ? "https" : req.protocol;
  return `${scheme}://${host}`;
};

const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "16kb" }));

// One structured log line per request, so Logs Insights can query fields instead of substrings.
app.use((req, res, next) => {
  const startedAt = Date.now();
  res.on("finish", () => {
    console.log(
      JSON.stringify({
        level: "INFO",
        method: req.method,
        path: req.path,
        statusCode: res.statusCode,
        durationMs: Date.now() - startedAt,
        requestId: req.get("lambda-web-request-id") || null,
      }),
    );
  });
  next();
});

app.use(express.static(path.join(__dirname, "public"), { index: "index.html" }));

app.get("/healthz", (req, res) => {
  res.json({
    ok: true,
    region: process.env.AWS_REGION || null,
    endpoint: req.get("lambda-web-endpoint-name") || null,
    requestId: req.get("lambda-web-request-id") || null,
    uptimeSeconds: Math.round(process.uptime()),
  });
});

app.post("/api/links", async (req, res) => {
  const { url, slug: requestedSlug } = req.body || {};
  let target;
  try {
    target = new URL(url);
    if (!["http:", "https:"].includes(target.protocol)) throw new Error("scheme");
  } catch {
    return res.status(400).json({ error: "url must be an absolute http(s) URL" });
  }
  if (requestedSlug !== undefined && !SLUG_PATTERN.test(requestedSlug)) {
    return res.status(400).json({ error: "slug must match [A-Za-z0-9_-]{3,32}" });
  }

  const slug = requestedSlug || randomSlug();
  const item = { slug, url: target.href, createdAt: new Date().toISOString(), clicks: 0 };
  try {
    await ddb.send(
      new PutCommand({
        TableName: TABLE,
        Item: item,
        ConditionExpression: "attribute_not_exists(slug)",
      }),
    );
  } catch (error) {
    if (error.name === "ConditionalCheckFailedException") {
      return res.status(409).json({ error: `slug ${slug} is already taken` });
    }
    throw error;
  }

  const shortUrl = `${baseUrl(req)}/${slug}`;
  const png = await QRCode.toBuffer(shortUrl, { type: "png", width: 256, margin: 1 });
  await s3.send(
    new PutObjectCommand({
      Bucket: BUCKET,
      Key: `qr/${slug}.png`,
      Body: png,
      ContentType: "image/png",
    }),
  );

  res.status(201).json({ ...item, shortUrl, qr: `/api/links/${slug}/qr.png` });
});

app.get("/api/links", async (req, res) => {
  const { Items = [] } = await ddb.send(new ScanCommand({ TableName: TABLE, Limit: 50 }));
  Items.sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
  res.json({
    links: Items.map((item) => ({
      ...item,
      shortUrl: `${baseUrl(req)}/${item.slug}`,
      qr: `/api/links/${item.slug}/qr.png`,
    })),
  });
});

app.get("/api/links/:slug", async (req, res) => {
  const { Item } = await ddb.send(
    new GetCommand({ TableName: TABLE, Key: { slug: req.params.slug } }),
  );
  if (!Item) return res.status(404).json({ error: "not found" });
  res.json({ ...Item, shortUrl: `${baseUrl(req)}/${Item.slug}`, qr: `/api/links/${Item.slug}/qr.png` });
});

// The PNG is streamed straight from S3 to the client; the platform relays the body as it arrives.
app.get("/api/links/:slug/qr.png", async (req, res) => {
  let object;
  try {
    object = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `qr/${req.params.slug}.png` }));
  } catch (error) {
    if (error.name === "NoSuchKey") return res.status(404).json({ error: "not found" });
    throw error;
  }
  res.set("content-type", "image/png");
  res.set("cache-control", "public, max-age=86400");
  object.Body.pipe(res);
});

// The redirect itself: a real 302 with a Location header, and an atomic counter update.
app.get("/:slug", async (req, res) => {
  const { slug } = req.params;
  if (!SLUG_PATTERN.test(slug)) return res.status(404).json({ error: "not found" });
  let updated;
  try {
    updated = await ddb.send(
      new UpdateCommand({
        TableName: TABLE,
        Key: { slug },
        UpdateExpression: "ADD clicks :one SET lastClickAt = :now",
        ConditionExpression: "attribute_exists(slug)",
        ExpressionAttributeValues: { ":one": 1, ":now": new Date().toISOString() },
        ReturnValues: "ALL_NEW",
      }),
    );
  } catch (error) {
    if (error.name === "ConditionalCheckFailedException") {
      return res.status(404).json({ error: "not found" });
    }
    throw error;
  }
  res.redirect(302, updated.Attributes.url);
});

app.use((error, req, res, _next) => {
  console.error(JSON.stringify({ level: "ERROR", path: req.path, error: error.message }));
  res.status(500).json({ error: "internal error" });
});

const [host, port] = (process.env.AWS_LAMBDA_HTTP_ENDPOINT || "127.0.0.1:3000").split(":");
const server = app.listen(Number(port), host, () => {
  console.log(`Server listening on ${host}:${port}`);
});

process.on("SIGTERM", () => {
  console.log("Shutting down gracefully");
  server.close(() => process.exit(0));
});
