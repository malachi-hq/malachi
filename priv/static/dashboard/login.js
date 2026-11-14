'use strict';

// The login page's script, served as /login.js so the Content-Security-Policy can say script-src 'self' with
// no 'unsafe-inline'. It is public: the page that loads it has no session yet.

// An error is an application/problem+json body whose type is a translation key; anything else gets the
// generic message.
function getErrorMessage(type) {
  const messages = {
    'errors.auth.invalid_credentials': 'Invalid username or password',
    'errors.http.rate_limited': 'Too many attempts. Please try again later.',
    'errors.http.invalid_request': 'Enter a username and a password.',
    'errors.http.header_fields_too_large': 'The request was too large. Clear the cookies for this site and try again.'
  };
  return Object.prototype.hasOwnProperty.call(messages, type) ? messages[type] : 'An error occurred. Please try again.';
}

function startLogin() {
  const form = document.getElementById('loginForm');
  const errorDiv = document.getElementById('error');
  const loginBtn = document.getElementById('loginBtn');

  form.addEventListener('submit', async e => {
    e.preventDefault();

    const username = document.getElementById('username').value;
    const password = document.getElementById('password').value;

    errorDiv.classList.remove('show');
    loginBtn.disabled = true;
    loginBtn.textContent = 'Logging in...';

    try {
      const response = await fetch('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password })
      });

      const data = await response.json();

      if (response.ok && data.s === 'ok') {
        // The cookie is set by the server (HttpOnly); go to the dashboard.
        window.location.href = '/';
      } else {
        throw new Error(data.type || 'Login failed');
      }
    } catch (error) {
      errorDiv.textContent = getErrorMessage(error.message);
      errorDiv.classList.add('show');
      loginBtn.disabled = false;
      loginBtn.textContent = 'Login';
    }
  });
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startLogin);
  } else {
    startLogin();
  }
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { getErrorMessage };
}
