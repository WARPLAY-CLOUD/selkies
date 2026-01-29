/**
 * Конфигурация для подключения к серверу
 * Используется для отладки, когда веб-часть на другом сервере
 */
export interface ConnectionConfig {
  /** Хост сервера (например, "111.111.111.111" или "localhost") */
  host: string;
  /** Порт сервера (по умолчанию 8080) */
  port?: number;
  /** Использовать HTTPS/WSS (по умолчанию false) */
  secure?: boolean;
  /** Путь к приложению (по умолчанию "webrtc") */
  appName?: string;
  /** Базовый путь (по умолчанию "/") */
  /** Базовый путь (по умолчанию "/") */
  basePath?: string;
  /** ICE сервера для WebRTC */
  iceServers?: RTCIceServer[];
  /**
   * WebSocket URL для control-plane (warplay control).
   * Если не задан, будет построен из host/port/secure и controlSignallingPath.
   */
  controlSignallingUrl?: string;
  /** Путь прокси до control-plane websocket на том же origin (по умолчанию "/control/ws"). */
  controlSignallingPath?: string;
  /** Включить ли control-plane (по умолчанию true). */
  controlEnabled?: boolean;
}

/**
 * Режим разработки - когда веб-часть на другом сервере
 */
export interface DevConfig {
  /** Включен ли режим разработки */
  enabled: boolean;
  /** Конфигурация подключения для режима разработки */
  connection?: ConnectionConfig;
}

/**
 * Глобальная конфигурация приложения
 */
export interface AppConfig {
  /** Режим разработки */
  dev?: DevConfig;
  /** Конфигурация подключения по умолчанию (используется если dev не включен) */
  defaultConnection?: ConnectionConfig;
}

/**
 * Получить конфигурацию подключения
 * Если включен dev режим, используется dev.connection
 * Иначе используется defaultConnection или значения из window.location
 * 
 * Поддерживает URL параметры:
 * - ?server=IP - указать сервер для подключения
 * - &port=PORT - указать порт
 * - &app=APPNAME - указать имя приложения
 * - &debug=true - включить отладку
 */
export function getConnectionConfig(config?: AppConfig): ConnectionConfig {
  if (config?.dev?.enabled && config.dev.connection) {
    return config.dev.connection;
  }

  if (config?.defaultConnection) {
    return config.defaultConnection;
  }

  // Парсим URL параметры
  const urlParams = new URLSearchParams(window.location.search);
  const serverParam = urlParams.get('server');
  const portParam = urlParams.get('port');
  const appParam = urlParams.get('app');
  const secureParam = urlParams.get('secure');
  const controlEnabledParam = urlParams.get('control');
  const controlWsParam = urlParams.get('control_ws');
  const controlPathParam = urlParams.get('control_path');

  // TURN параметры из URL
  const turnHost = urlParams.get('turn_host');
  const turnPort = urlParams.get('turn_port');
  const turnUsername = urlParams.get('turn_username');
  const turnPassword = urlParams.get('turn_password');
  const turnProtocol = urlParams.get('turn_protocol') || 'udp';

  // По умолчанию используем текущий location или параметры из URL
  const protocol = secureParam ? (secureParam === 'true' ? 'https' : 'http')
    : (window.location.protocol === 'https:' ? 'https' : 'http');
  const host = serverParam || window.location.hostname;

  // Если указан server в параметрах, но не указан port - используем стандартные порты
  // Иначе используем port из URL или из window.location
  let port: number;
  if (portParam) {
    port = parseInt(portParam);
  } else if (serverParam) {
    // Если указан внешний сервер, но порт не указан - используем стандартные порты
    port = protocol === 'https' ? 443 : 80;
  } else {
    // Если используем текущий location - берём его порт
    port = window.location.port ? parseInt(window.location.port)
      : (protocol === 'https' ? 443 : 80);
  }

  // Парсим appName из URL параметров или pathname
  let appName = appParam;
  if (!appName) {
    const pathname = window.location.pathname;
    appName = pathname.endsWith('/')
      ? pathname.split('/').filter(p => p)[0] || 'webrtc'
      : pathname.split('/').filter(p => p).pop() || 'webrtc';
  }

  const connectionConfig: ConnectionConfig = {
    host,
    port,
    secure: protocol === 'https',
    appName,
    basePath: '/',
  };

  // control-plane websocket (warplay control server)
  if (controlWsParam) {
    connectionConfig.controlSignallingUrl = controlWsParam;
  } else {
    connectionConfig.controlSignallingPath = controlPathParam || '/control/ws';
  }
  if (controlEnabledParam) {
    connectionConfig.controlEnabled = controlEnabledParam !== 'false';
  } else {
    connectionConfig.controlEnabled = true;
  }

  if (turnHost) {
    const tPort = turnPort ? `:${turnPort}` : '';
    connectionConfig.iceServers = [{
      urls: `turn:${turnHost}${tPort}?transport=${turnProtocol}`,
      username: turnUsername || undefined,
      credential: turnPassword || undefined
    }];
  }

  return connectionConfig;
}

/**
 * Создать URL для WebSocket подключения
 */
export function createSignallingUrl(config: ConnectionConfig): string {
  const protocol = config.secure ? 'wss' : 'ws';
  const port = config.port ? `:${config.port}` : '';
  const basePath = config.basePath || '/';
  const appName = config.appName || 'webrtc';

  return `${protocol}://${config.host}${port}${basePath}${appName}/signalling/`;
}

/**
 * Создать URL для WebSocket control-plane (warplay control server).
 * Предполагается, что NGINX проксирует его на внутренний WS signalling сервера.
 */
export function createControlSignallingUrl(config: ConnectionConfig): string {
  if (config.controlSignallingUrl) {
    return config.controlSignallingUrl;
  }
  const protocol = config.secure ? 'wss' : 'ws';
  const port = config.port ? `:${config.port}` : '';
  const basePath = config.basePath || '/';
  const path = (config.controlSignallingPath || '/control/ws').replace(/^\//, '');
  return `${protocol}://${config.host}${port}${basePath}${path}`;
}

