import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import { getConnectionConfig } from './config';
import './index.css';

const config = getConnectionConfig();

// Default TURN config if not provided in URL
if (!config.iceServers || config.iceServers.length === 0) {
  config.iceServers = [{
    urls: 'turn:turn.warplay.cloud:3478?transport=udp',
    username: 'some_user',
    credential: 'some_password'
  }];
  console.log('Using default TURN config');
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App connectionConfig={config} />
  </React.StrictMode>
);


