{{/*
Renders one TileserverGL instance's Deployment + Service + (PVC, unless
persistence.existingClaim is set) + (Route, if route.enabled) -- called
once per entry in .Values.tileservers by templates/tileservers.yaml.
Takes a dict: "root" (the top-level `.`), "key" (the tileservers.* map key,
e.g. "epsg3857"), and "cfg" (that key's value, e.g. .Values.tileservers.epsg3857).
*/}}
{{- define "rbt.tileserver" -}}
{{- $root := .root -}}
{{- $cfg := .cfg -}}
{{- $key := .key -}}
{{- $fullname := include "rbt.fullname" $root -}}
{{- $name := printf "%s-%s" $fullname $key -}}
{{- $s3SecretName := include "rbt.s3SecretName" $root -}}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "rbt.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $key }}
spec:
  replicas: 1
  # The mbtiles PVC below is ReadWriteOnce -- a rolling update would try to
  # start the new pod before the old one (and its volume attachment)
  # releases the claim, so recreate instead.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "rbt.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $key }}
  template:
    metadata:
      labels:
        {{- include "rbt.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ $key }}
    spec:
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml $root.Values.podSecurityContext | nindent 8 }}
      initContainers:
        # Populates the PVC from S3 -- MBTiles plus the shared fonts/ and
        # styles/ trees (see ../files/scripts/fetch-s3.sh). Fonts/styles
        # are the OpenShift equivalent of docker-compose.4087.yaml's bind
        # mounts, without a second image. The fetch helpers no-op when
        # their URI is blank, which is expected when
        # persistence.existingClaim points at a PVC populated out-of-band.
        - name: fetch-s3
          image: "{{ $root.Values.mbtiles.awsCliImage.repository }}:{{ $root.Values.mbtiles.awsCliImage.tag }}"
          imagePullPolicy: {{ $root.Values.mbtiles.awsCliImage.pullPolicy }}
          command: ["bash", "/scripts/fetch-s3.sh"]
          env:
            - name: HOME
              value: /tmp
            - name: DATA_DIR
              value: /data
            - name: RBT_S3_URI
              value: {{ $cfg.s3.rbtUri | quote }}
            - name: TERRAIN_S3_URI
              value: {{ $cfg.s3.terrainUri | quote }}
            - name: FONTS_S3_URI
              value: {{ $root.Values.s3.fontsUri | quote }}
            - name: STYLES_S3_URI
              value: {{ $root.Values.s3.stylesUri | quote }}
            - name: FORCE_DOWNLOAD
              value: {{ $root.Values.mbtiles.force | quote }}
            - name: AWS_REGION
              value: {{ $root.Values.s3.region | quote }}
            {{- if $root.Values.s3.endpointUrl }}
            - name: AWS_ENDPOINT_URL
              value: {{ $root.Values.s3.endpointUrl | quote }}
            {{- end }}
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: {{ $s3SecretName }}
                  key: access-key-id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: {{ $s3SecretName }}
                  key: secret-access-key
          securityContext:
            {{- toYaml $root.Values.containerSecurityContext | nindent 12 }}
          volumeMounts:
            - name: mbtiles
              mountPath: /data
            - name: fetch-script
              mountPath: /scripts
              readOnly: true
      containers:
        - name: tileserver
          image: "{{ $root.Values.tileserverImage.repository }}:{{ $root.Values.tileserverImage.tag }}"
          imagePullPolicy: {{ $root.Values.tileserverImage.pullPolicy }}
          # Equivalent to docker-compose.4087.yaml's `command: ["-c",
          # "/config/config.json"]` -- Compose's "command" overrides the
          # image's CMD, not its ENTRYPOINT (docker-entrypoint.sh), so the
          # Kubernetes analog is "args", leaving "command" (ENTRYPOINT)
          # alone.
          args:
            - "-c"
            - "/config/config.json"
            {{- if $cfg.route.publicUrl }}
            - "--public_url"
            - {{ $cfg.route.publicUrl | quote }}
            {{- end }}
          env:
            - name: HOME
              value: /tmp
          ports:
            - name: http
              containerPort: {{ $cfg.containerPort }}
              protocol: TCP
          securityContext:
            {{- toYaml $root.Values.containerSecurityContext | nindent 12 }}
          volumeMounts:
            - name: mbtiles
              mountPath: /fonts
              subPath: fonts
            - name: mbtiles
              mountPath: /styles
              subPath: styles
            - name: tileserver-config
              mountPath: /config
              readOnly: true
            - name: mbtiles
              mountPath: /data
            - name: dshm
              mountPath: /dev/shm
          # Matches docker-compose.4087.yaml's healthcheck (same command,
          # same 180s start_period) -- startupProbe covers the initial
          # MBTiles/style load so the readiness/liveness probes below can
          # use tighter thresholds once the container is actually up.
          startupProbe:
            exec:
              command: ["node", "/usr/src/app/src/healthcheck.js"]
            periodSeconds: 10
            failureThreshold: 24
            timeoutSeconds: 10
          readinessProbe:
            exec:
              command: ["node", "/usr/src/app/src/healthcheck.js"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          livenessProbe:
            exec:
              command: ["node", "/usr/src/app/src/healthcheck.js"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          resources:
            {{- toYaml $cfg.resources | nindent 12 }}
      volumes:
        - name: tileserver-config
          configMap:
            name: {{ $fullname }}-tileserver-config
            items:
              - key: config.json
                path: config.json
        - name: fetch-script
          configMap:
            name: {{ $fullname }}-tileserver-config
            defaultMode: 0755
            items:
              - key: fetch-s3.sh
                path: fetch-s3.sh
        # docker-compose.4087.yaml's `shm_size: ${TILESERVER_SHM_SIZE:-2gb}`.
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: {{ $cfg.shm.sizeLimit }}
        - name: mbtiles
          persistentVolumeClaim:
            claimName: {{ $cfg.persistence.existingClaim | default (printf "%s-mbtiles" $name) }}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  # Not `$name` -- this is the hostname mapproxy's rewritten source URLs
  # point at (see templates/configmap-mapproxy.yaml), so it comes straight
  # from values.yaml's tileservers.<key>.serviceName instead of the
  # release-scoped naming every other resource here uses.
  name: {{ $cfg.serviceName }}
  labels:
    {{- include "rbt.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $key }}
spec:
  type: ClusterIP
  selector:
    {{- include "rbt.selectorLabels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $key }}
  ports:
    - name: http
      port: {{ $cfg.containerPort }}
      targetPort: http
{{- if not $cfg.persistence.existingClaim }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ $name }}-mbtiles
  labels:
    {{- include "rbt.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $key }}
spec:
  accessModes:
    {{- toYaml $cfg.persistence.accessModes | nindent 4 }}
  {{- if $cfg.persistence.storageClassName }}
  storageClassName: {{ $cfg.persistence.storageClassName }}
  {{- end }}
  resources:
    requests:
      storage: {{ $cfg.persistence.size }}
{{- end }}
{{- if $cfg.route.enabled }}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ $name }}
  labels:
    {{- include "rbt.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ $key }}
  {{- with $cfg.route.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if $cfg.route.host }}
  host: {{ $cfg.route.host }}
  {{- end }}
  to:
    kind: Service
    name: {{ $cfg.serviceName }}
  port:
    targetPort: http
  tls:
    termination: {{ $cfg.route.tls.termination }}
    insecureEdgeTerminationPolicy: {{ $cfg.route.tls.insecureEdgeTerminationPolicy }}
{{- end }}
{{- end -}}
