FROM node:22.14.0-alpine

WORKDIR /app

RUN apk add --no-cache git && npm install -g pnpm@10

COPY ./package.json ./pnpm-lock.yaml ./

RUN pnpm install --frozen-lockfile

COPY . .

EXPOSE 5173

CMD ["pnpm", "run", "dev", "--host"]