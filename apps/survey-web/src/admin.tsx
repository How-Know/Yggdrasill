import React from 'react';
import { createRoot } from 'react-dom/client';
import './global.css';
import AdminPage from './pages/AdminPage';

const root = createRoot(document.getElementById('root')!);
root.render(
  <React.StrictMode>
    <AdminPage />
  </React.StrictMode>
);



