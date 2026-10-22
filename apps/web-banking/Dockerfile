# web-banking (Node.js). No OTel SDK: EDOT Node.js is injected by the OTel Operator.
# Debian (glibc) base for compatibility with the injected agent.
FROM node:22.23.3-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:22.23.3-bookworm-slim
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json server.js ./
# "node" user (uid 1000) ships with the official image
USER 1000
EXPOSE 8080
CMD ["node", "server.js"]
