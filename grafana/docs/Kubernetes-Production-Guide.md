# Grafana Production Hardened v1 on Kubernetes (K3s)

## الهدف

بناء Grafana على Kubernetes بطريقة قريبة من Production باستخدام:

* K3s
* Traefik Ingress
* Persistent Storage
* Secrets
* ConfigMaps
* Health Checks
* Resource Limits

البيئة المستهدفة:

* Ubuntu Server
* Single VPS
* K3s Cluster
* Traefik (Built-in)

---

# Architecture

Browser
↓
Traefik Ingress
↓
Grafana Service
↓
Grafana Pod
↓
Persistent Volume Claim
↓
Persistent Volume

---

# Namespace

الغرض:

عزل Grafana داخل مساحة مستقلة خاصة بالمراقبة.

namespace.yaml

apiVersion: v1
kind: Namespace

metadata:
name: monitoring

التطبيق:

kubectl apply -f namespace.yaml

---

# Persistent Storage

الغرض:

ضمان عدم فقدان:

* Dashboards
* Users
* Data Sources
* Settings

في حالة إعادة تشغيل Pod.

grafana-pvc.yaml

apiVersion: v1
kind: PersistentVolumeClaim

metadata:
name: grafana-storage
namespace: monitoring

spec:
accessModes:
- ReadWriteOnce

resources:
requests:
storage: 5Gi

التطبيق:

kubectl apply -f grafana-pvc.yaml

التحقق:

kubectl get pvc -n monitoring
kubectl get pv

---

# Secrets

الغرض:

تخزين البيانات الحساسة خارج Deployment.

إنشاء Secret:

kubectl create secret generic grafana-secret 
--namespace monitoring 
--from-literal=admin-user=admin 
--from-literal=admin-password='CHANGE_ME'

التحقق:

kubectl get secrets -n monitoring

---

# ConfigMap

الغرض:

فصل الإعدادات غير الحساسة عن Deployment.

grafana-configmap.yaml

apiVersion: v1
kind: ConfigMap

metadata:
name: grafana-config
namespace: monitoring

data:
GF_SERVER_ROOT_URL: "http://grafana.local"
GF_USERS_ALLOW_SIGN_UP: "false"
GF_SECURITY_ALLOW_EMBEDDING: "true"

التطبيق:

kubectl apply -f grafana-configmap.yaml

---

# Deployment

الغرض:

تشغيل Grafana بطريقة Production Hardened.

المزايا:

* Version Pinning
* Resources
* Health Checks
* Security Context
* Secret Integration
* ConfigMap Integration
* Persistent Storage

grafana-deployment.yaml

apiVersion: apps/v1
kind: Deployment

metadata:
name: grafana
namespace: monitoring

spec:
replicas: 1

selector:
matchLabels:
app: grafana

template:
metadata:
labels:
app: grafana

```
spec:
  securityContext:
    fsGroup: 472

  containers:
    - name: grafana

      image: grafana/grafana:12.1.1
      imagePullPolicy: IfNotPresent

      ports:
        - containerPort: 3000

      resources:
        requests:
          cpu: "100m"
          memory: "256Mi"

        limits:
          cpu: "500m"
          memory: "512Mi"

      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false

      env:
        - name: GF_SECURITY_ADMIN_USER
          valueFrom:
            secretKeyRef:
              name: grafana-secret
              key: admin-user

        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: grafana-secret
              key: admin-password

        - name: GF_SERVER_ROOT_URL
          valueFrom:
            configMapKeyRef:
              name: grafana-config
              key: GF_SERVER_ROOT_URL

        - name: GF_USERS_ALLOW_SIGN_UP
          valueFrom:
            configMapKeyRef:
              name: grafana-config
              key: GF_USERS_ALLOW_SIGN_UP

        - name: GF_SECURITY_ALLOW_EMBEDDING
          valueFrom:
            configMapKeyRef:
              name: grafana-config
              key: GF_SECURITY_ALLOW_EMBEDDING

      startupProbe:
        httpGet:
          path: /api/health
          port: 3000
        failureThreshold: 30
        periodSeconds: 10

      readinessProbe:
        httpGet:
          path: /api/health
          port: 3000
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 5

      livenessProbe:
        httpGet:
          path: /api/health
          port: 3000
        initialDelaySeconds: 30
        periodSeconds: 30
        timeoutSeconds: 5

      volumeMounts:
        - name: grafana-storage
          mountPath: /var/lib/grafana

  volumes:
    - name: grafana-storage
      persistentVolumeClaim:
        claimName: grafana-storage
```

التطبيق:

kubectl apply -f grafana-deployment.yaml

---

# Service

الغرض:

إعطاء Grafana عنوانًا ثابتًا داخل Cluster.

grafana-service.yaml

apiVersion: v1
kind: Service

metadata:
name: grafana
namespace: monitoring

spec:
selector:
app: grafana

ports:
- name: http
port: 3000
targetPort: 3000

type: ClusterIP

التطبيق:

kubectl apply -f grafana-service.yaml

---

# Ingress

الغرض:

الوصول إلى Grafana من المتصفح عبر Traefik.

grafana-ingress.yaml

apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
name: grafana
namespace: monitoring

annotations:
traefik.ingress.kubernetes.io/router.entrypoints: web

spec:
ingressClassName: traefik

rules:
- host: grafana.local

```
  http:
    paths:
      - path: /
        pathType: Prefix

        backend:
          service:
            name: grafana
            port:
              number: 3000
```

التطبيق:

kubectl apply -f grafana-ingress.yaml

---

# Windows Hosts File

إضافة:

192.168.1.50 grafana.local

المسار:

C:\Windows\System32\drivers\etc\hosts

---

# Deployment Verification

kubectl get pods -n monitoring
kubectl get deployment -n monitoring
kubectl get svc -n monitoring
kubectl get ingress -n monitoring

---

# Monitoring Resources

kubectl top pod -n monitoring

مثال ناجح:

CPU: 3m
Memory: 80Mi

---

# Rollout Verification

kubectl rollout status deployment/grafana -n monitoring

النتيجة المطلوبة:

deployment "grafana" successfully rolled out

---

# Troubleshooting

## PVC Pending

السبب:

WaitForFirstConsumer

الحل:

إنشاء Pod تستخدم الـ PVC.

---

## Login Failed

السبب:

Grafana أنشأت قاعدة البيانات قبل إضافة Secret.

الحل:

حذف PVC في بيئة Lab وإعادة الإنشاء.

---

## Ingress لا يعمل

التحقق:

kubectl get pods -n kube-system

يجب أن يكون Traefik Running.

---

# Production Readiness Score

Namespace: PASS
Persistent Storage: PASS
Secrets: PASS
ConfigMaps: PASS
Deployment: PASS
Service: PASS
Ingress: PASS
Resources: PASS
Health Checks: PASS
Version Pinning: PASS

التقييم النهائي:

Grafana Production Hardened v1

Suitable for:

* Single VPS
* K3s
* Small Production Environments

Future Enhancements:

* TLS
* Automated Backups
* Network Policies
* Alerting
* PodDisruptionBudget
