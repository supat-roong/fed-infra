apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow-server
  namespace: ${FED_NAMESPACE}
  labels:
    app: mlflow-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mlflow-server
  template:
    metadata:
      labels:
        app: mlflow-server
    spec:
      containers:
        - name: mlflow
          image: ${FED_MLFLOW_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - mlflow
            - server
            - --host
            - "0.0.0.0"
            - --port
            - "5000"
            - --backend-store-uri
            - /mlflow/mlruns
            - --default-artifact-root
            - s3://${FED_S3_BUCKET}
          env:
            - name: MLFLOW_S3_ENDPOINT_URL
              value: "http://${FED_S3_ENDPOINT}"
            - name: AWS_ACCESS_KEY_ID
              value: "${FED_S3_ACCESS_KEY}"
            - name: AWS_SECRET_ACCESS_KEY
              value: "${FED_S3_SECRET_KEY}"
            - name: MLFLOW_S3_IGNORE_TLS
              value: "true"
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: mlflow-storage
              mountPath: /mlflow
      volumes:
        - name: mlflow-storage
          persistentVolumeClaim:
            claimName: mlflow-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mlflow-pvc
  namespace: ${FED_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-service
  namespace: ${FED_NAMESPACE}
spec:
  selector:
    app: mlflow-server
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: ${FED_NODEPORT_MLFLOW}
  type: NodePort
