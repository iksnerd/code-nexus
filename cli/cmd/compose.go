package cmd

// composeYAML is what "nexus init" writes to ~/.nexus/docker-compose.yml. It
// mirrors the repo's docker-compose.yml, which a source checkout uses instead.
// A test fails if the images or container names drift apart.
const composeYAML = `services:
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    # "always", not "unless-stopped": Docker Desktop records its own shutdown as a
    # manual stop, and "unless-stopped" then skips auto-start when the daemon comes
    # back, leaving the server down until someone runs docker compose up by hand.
    restart: always
    # Loopback only: Qdrant has no API key here and holds every indexed repo's
    # code. code_nexus reaches it as qdrant:6333 on the compose network.
    ports:
      - "127.0.0.1:6333:6333"
      - "127.0.0.1:6334:6334"
    volumes:
      - qdrant_storage:/qdrant/storage:z
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/6333'"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - nexus

  code_nexus:
    image: iksnerd/code-nexus:latest
    container_name: code_nexus
    restart: always
    ports:
      - "4100:4100"
      - "3002:3002"
    environment:
      MIX_ENV: prod
      QDRANT_URL: "http://qdrant:6333"
      MCP_HTTP_PORT: "3002"
      OLLAMA_URL: "http://host.docker.internal:11434"
      OLLAMA_MODEL: "${OLLAMA_MODEL:-embeddinggemma:300m}"
      EMBEDDING_BACKEND: "${EMBEDDING_BACKEND:-}"
      WORKSPACE_HOST: "${WORKSPACE_HOST:-}"
    depends_on:
      qdrant:
        condition: service_healthy
    volumes:
      - ${WORKSPACE:-.}:/workspace:ro
    networks:
      - nexus
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'echo > /dev/tcp/localhost/4100'"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  qdrant_storage:

networks:
  nexus:
    driver: bridge
`
