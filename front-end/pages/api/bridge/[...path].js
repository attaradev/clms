import axios from 'axios'

export default async function handler(req, res) {
  const { path = [] } = req.query

  const base = process.env.BACKEND_API_HOST
  if (!base) {
    return res.status(500).json({ message: 'BACKEND_API_HOST is not set' })
  }

  const url = `${base}/api/${Array.isArray(path) ? path.join('/') : path}`

  try {
    const method = req.method?.toUpperCase() || 'GET'

    const headers = {}
    // forward auth header if present
    if (req.headers.authorization) headers['Authorization'] = req.headers.authorization
    // ensure JSON by default
    if (!headers['Content-Type'] && req.headers['content-type']) headers['Content-Type'] = req.headers['content-type']
    if (req.headers['accept']) headers['Accept'] = req.headers['accept']

    const { path: _omitPath, ...forwardedQuery } = req.query || {}

    const axiosConfig = {
      method,
      url,
      headers,
      // forward query string without the catch-all param
      params: forwardedQuery,
      // avoid treating non-2xx as throw; we proxy status codes
      validateStatus: () => true,
    }

    // Only attach body for methods that support it
    if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) {
      axiosConfig.data = req.body
    }

    const response = await axios(axiosConfig)
    return res.status(response.status).json(response.data)
  } catch (e) {
    // Network or unexpected error
    const message = e?.response?.data?.message || 'Upstream request failed'
    const status = e?.response?.status || 502
    return res.status(status).json({ message })
  }
}
