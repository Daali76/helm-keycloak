#!/bin/bash

# 1. Clean up existing mess
echo "🧹 Cleaning up old files and git history..."
rm -rf charts .github .git
rm -f Chart.yaml values.yaml deployment.yaml service.yaml _helpers.tpl

# 2. Create Directory Structure
echo "📂 Creating directory structure..."
mkdir -p .github/workflows
mkdir -p charts/keycloak/templates

# 3. Create GitHub Action Workflow
echo "📝 Creating .github/workflows/deploy.yml..."
cat <<'EOF' > .github/workflows/deploy.yml
name: Deploy Keycloak

on:
  push:
    branches:
      - main
    paths:
      - 'charts/keycloak/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Set up Helm
        uses: azure/setup-helm@v3
        with:
          version: 'v3.11.1'

      - name: Lint Helm Chart
        run: helm lint charts/keycloak/

      - name: Set up Kubectl
        uses: azure/setup-kubectl@v3
        
      - name: Write Kubeconfig
        run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBE_CONFIG }}" > ~/.kube/config
          chmod 600 ~/.kube/config

      - name: Deploy Keycloak
        run: |
          helm upgrade --install keycloak ./charts/keycloak \
            --namespace auth \
            --create-namespace \
            --wait \
            --timeout 10m0s
EOF

# 4. Create Chart.yaml
echo "📝 Creating charts/keycloak/Chart.yaml..."
cat <<'EOF' > charts/keycloak/Chart.yaml
apiVersion: v2
name: keycloak-custom
description: Keycloak with official quay.io image + Official Postgres
type: application
version: 0.2.0
appVersion: "26.0.0"
EOF

# 5. Create values.yaml (Updated for Postgres Connection)
echo "📝 Creating charts/keycloak/values.yaml..."
cat <<'EOF' > charts/keycloak/values.yaml
replicaCount: 1

image:
  repository: quay.io/keycloak/keycloak
  pullPolicy: IfNotPresent
  tag: "26.0.0"

service:
  type: ClusterIP
  port: 8080

resources:
  limits:
    cpu: 1000m
    memory: 1024Mi
  requests:
    cpu: 500m
    memory: 512Mi

# Database Configuration (Internal Postgres)
postgres:
  image: "postgres:16"
  dbName: "keycloak"
  user: "keycloak"
  password: "password"
  serviceName: "postgres-db"

env:
  KEYCLOAK_ADMIN: "admin"
  KEYCLOAK_ADMIN_PASSWORD: "admin"
  # Start command needs to know about DB now
  KC_COMMAND: "start-dev"
  
  # Connect to the internal Postgres Service
  KC_DB: "postgres"
  KC_DB_URL: "jdbc:postgresql://postgres-db:5432/keycloak"
  KC_DB_USERNAME: "keycloak"
  KC_DB_PASSWORD: "password"
  KC_PROXY: "edge"
  KC_HOSTNAME_STRICT: "false"
  KC_HTTP_ENABLED: "true"
EOF

# 6. Create deployment.yaml (Keycloak)
echo "📝 Creating charts/keycloak/templates/deployment.yaml..."
cat <<'EOF' > charts/keycloak/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "keycloak.fullname" . }}
  labels:
    {{- include "keycloak.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "keycloak.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "keycloak.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: 
            - {{ .Values.env.KC_COMMAND }}
          env:
            {{- range $key, $val := .Values.env }}
            - name: {{ $key }}
              value: {{ $val | quote }}
            {{- end }}
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /realms/master
              port: http
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /realms/master
              port: http
            initialDelaySeconds: 120
            periodSeconds: 20
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF

# 7. Create service.yaml (Keycloak)
echo "📝 Creating charts/keycloak/templates/service.yaml..."
cat <<'EOF' > charts/keycloak/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "keycloak.fullname" . }}
  labels:
    {{- include "keycloak.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "keycloak.selectorLabels" . | nindent 4 }}
EOF

# 8. Create Postgres Deployment (New)
echo "📝 Creating charts/keycloak/templates/postgres-deployment.yaml..."
cat <<'EOF' > charts/keycloak/templates/postgres-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-db
  labels:
    app: postgres
    {{- include "keycloak.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: {{ .Values.postgres.image }}
          env:
            - name: POSTGRES_DB
              value: {{ .Values.postgres.dbName }}
            - name: POSTGRES_USER
              value: {{ .Values.postgres.user }}
            - name: POSTGRES_PASSWORD
              value: {{ .Values.postgres.password }}
          ports:
            - containerPort: 5432
          # Simple check to ensure DB is up
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "keycloak"]
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "keycloak"]
            initialDelaySeconds: 20
            periodSeconds: 10
EOF

# 9. Create Postgres Service (New)
echo "📝 Creating charts/keycloak/templates/postgres-service.yaml..."
cat <<'EOF' > charts/keycloak/templates/postgres-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.postgres.serviceName }}
  labels:
    app: postgres
spec:
  ports:
    - port: 5432
      targetPort: 5432
  selector:
    app: postgres
EOF

# 10. Create _helpers.tpl
echo "📝 Creating charts/keycloak/templates/_helpers.tpl..."
cat <<'EOF' > charts/keycloak/templates/_helpers.tpl
{{/* Expand the name of the chart. */}}
{{- define "keycloak.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Create a default fully qualified app name. */}}
{{- define "keycloak.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Common labels */}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
{{ include "keycloak.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels */}}
{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keycloak.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Create chart name and version */}}
{{- define "keycloak.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
EOF

# 11. Initialize Git and Force Push
echo "🚀 Initializing Git and Pushing to GitHub..."
git init
git branch -M main
git add .
git commit -m "Fresh Start: Keycloak + Postgres (Official Images)"

# Set remote (Replace URL if needed)
git remote add origin https://github.com/Daali76/helm-keycloak.git

# Force push to overwrite everything
git push -u origin main --force

echo "✅ Done! Check GitHub Actions now."