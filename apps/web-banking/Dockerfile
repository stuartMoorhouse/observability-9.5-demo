# web-banking (Node.js). No OTel SDK: EDOT Node.js is injected by the OTel Operator.
# Debian (glibc) base for compatibility with the injected agent.
FROM node:22.23.3-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# Browser UI: bundle the OpenTelemetry web SDK and UI code into dist/bundle.js.
FROM node:22.23.3-bookworm-slim AS frontend
WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/src ./src
RUN npm run build

FROM node:22.23.3-bookworm-slim
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./
COPY --chown=node:node public ./public
COPY --from=frontend --chown=node:node /frontend/dist ./public
# "node" user (uid 1000) ships with the official image
USER 1000
EXPOSE 8080 8081
CMD ["node", "server.js"]
