apiVersion: v1
kind: Secret

metadata:
  name: shopixy-app-credentials
  namespace: rabbitmq

type: Opaque

stringData:
  username: ${SHOPIXY_RABBITMQ_USERNAME}
  password: ${SHOPIXY_RABBITMQ_PASSWORD}
