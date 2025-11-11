# Configuración SGI - Sistema de Gestión de Información

Este directorio contiene los archivos de configuración para el Sistema de Gestión de Información (SGI).

## 📋 Archivos de Configuración

### Archivos que DEBES subir al repositorio:
- ✅ `.env-ejemplo` - Plantilla con todos los parámetros necesarios
- ✅ `.seguridad-ejemplo` - Plantilla de configuración de seguridad
- ✅ `docker-compose.yml` - Configuración de Docker
- ✅ `README.md` - Esta documentación

### Archivos que NO debes subir (están en .gitignore):
- ❌ `.env-mio*` - Tus archivos de configuración reales
- ❌ `.env-local` - Configuración local
- ❌ `.seguridad` - Archivo de seguridad con datos reales

## 🚀 Configuración Inicial

### 1. Crear tu archivo de configuración

```bash
# Copiar la plantilla
cp .env-ejemplo .env-mio

# Editar con tus valores reales
nano .env-mio
```

### 2. Parámetros Críticos a Configurar

#### 🔐 Seguridad (Sección [APP])

**Generar claves de encriptación:**
```bash
# APP_KEY (32 caracteres hexadecimales)
openssl rand -hex 16

# APP_FIRSTKEY (base64, 32 bytes)
openssl rand -base64 32

# APP_SECONDKEY (base64, 64 bytes)
openssl rand -base64 64
```

**⚠️ IMPORTANTE:** Nunca uses las claves del ejemplo en producción.

#### 📧 Correo (Sección [MAIL])

- `MAIL_TOKEN`: Solicitar al equipo de infraestructura
- `MAIL_URL`: Servicio de correo web institucional
- `MAIL_OPERADOR`: Email del responsable técnico

#### 🔑 LDAP/Active Directory (Sección [LDAP])

- `LDAP_HOST`: Servidor AD institucional
- `LDAP_DOMAIN`: Dominio de la organización
- `LDAP_LTOKEN`: Token de autenticación (solicitar a TI)

#### 💾 Bases de Datos

**Oracle** (Sección [ORACLE])
- Host, puerto, base de datos
- Usuario y contraseña
- Charset: AL32UTF8 (recomendado)

**MySQL** (Sección [MYSQL])
- Host, puerto, base de datos
- Usuario y contraseña
- Charset: utf8mb4 (recomendado)

**PostgreSQL** y **SQL Server**: Similar a las anteriores

#### 🗄️ Redis (Sección [REDIS])

- `REDIS_HOST`: Nombre del contenedor Docker o IP
- `REDIS_PORT`: Generalmente 6379
- `REDIS_PASSWORD`: Contraseña fuerte (cambiar en producción)

#### 🏛️ DINARDAP (Sección [DINARDAP])

Integración con servicios del Estado ecuatoriano:
- `DINARDAP_APLICACION`: Código asignado
- `DINARDAP_PASSWORDAPP`: Contraseña de aplicación
- **Solicitar credenciales** al equipo de DINARDAP

## 🔧 Configuración por Ambiente

### Desarrollo Local
```ini
APP_ENV=local
APP_DEBUG=true
APP_DISPLAYERROR=1
DB_LOG_QUERIES=true
```

### Producción
```ini
APP_ENV=production
APP_DEBUG=false
APP_DISPLAYERROR=0
DB_LOG_QUERIES=false
```

## 📚 Documentación de Parámetros

### Formatos de Fecha y Hora

- PHP: `d/m/Y` (día/mes/año)
- Oracle: `DD/MM/YYYY HH24:MI:SS`
- MySQL: `%Y-%m-%d %H:%i:%s`

### Límites de Subida de Archivos

| Parámetro | Valor Recomendado |
|-----------|-------------------|
| Tamaño máximo total | 250 MB |
| Número máximo de archivos | 100 |
| Tamaño por archivo | 100 MB |

### Extensiones de Archivo Permitidas

```
.pdf, .doc, .docx, .txt, .jpg, .jpeg, .png, .gif,
.xlsx, .xls, .csv, .mp3, .wav, .ogg, .zip, .rar
```

## 🐳 Docker

### Iniciar servicios
```bash
docker-compose up -d
```

### Ver logs
```bash
docker-compose logs -f
```

### Detener servicios
```bash
docker-compose down
```

## ❓ Solución de Problemas

### Error de conexión a base de datos
1. Verificar que el host y puerto sean correctos
2. Confirmar usuario y contraseña
3. Verificar que el firewall permita la conexión
4. Revisar logs: `docker-compose logs`

### Error de autenticación LDAP
1. Verificar que `LDAP_HOST` sea accesible
2. Confirmar que `LDAP_LTOKEN` sea válido
3. Verificar conectividad de red con el servidor AD

### Redis no conecta
1. Verificar que el contenedor esté corriendo: `docker ps`
2. Confirmar puerto correcto (6379)
3. Verificar contraseña en `REDIS_PASSWORD`

## 📞 Contactos

- **Infraestructura**: Para tokens y accesos de servicios web
- **TI**: Para credenciales LDAP/AD
- **DINARDAP**: Para códigos de aplicación y contraseñas

## 🔒 Buenas Prácticas de Seguridad

1. ✅ Usa contraseñas únicas y fuertes para cada servicio
2. ✅ Rota las credenciales periódicamente
3. ✅ Nunca compartas archivos `.env-mio*` en chats o emails
4. ✅ Usa `.env-ejemplo` como referencia, no como configuración real
5. ✅ Mantén backups seguros de tus archivos de configuración
6. ✅ Revisa que `.gitignore` excluya archivos sensibles antes de hacer commit

## 📝 Notas Adicionales

- Las claves del archivo `.env-ejemplo` son **EJEMPLOS** - no las uses en producción
- Los valores de ejemplo pueden no funcionar - usa tus credenciales reales
- Mantén este README actualizado cuando agregues nuevos parámetros
