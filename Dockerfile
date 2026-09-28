# ---- Build stage ----
FROM node:20-alpine AS build
WORKDIR /app
COPY app/package.json ./
RUN npm install --omit=dev
COPY app/ ./

# ---- Runtime stage ----
FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app ./
EXPOSE 8080
USER node
CMD ["node", "server.js"]
