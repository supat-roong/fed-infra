apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: temporal-postgresql
  namespace: ${FED_TEMPORAL_NAMESPACE}
spec:
  serviceName: temporal-postgresql
  replicas: 1
  selector:
    matchLabels:
      app: temporal-postgresql
  template:
    metadata:
      labels:
        app: temporal-postgresql
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          env:
            - name: POSTGRES_USER
              value: "${FED_TEMPORAL_DB_USER}"
            - name: POSTGRES_PASSWORD
              value: "${FED_TEMPORAL_DB_PASSWORD}"
            - name: POSTGRES_DB
              value: "${FED_TEMPORAL_DB_NAME}"
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "${FED_TEMPORAL_DB_USER}"]
            initialDelaySeconds: 10
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata:
        name: pgdata
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: temporal-postgresql
  namespace: ${FED_TEMPORAL_NAMESPACE}
spec:
  selector:
    app: temporal-postgresql
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
