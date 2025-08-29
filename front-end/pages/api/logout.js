import withSession from '@/lib/session'
import axios from 'axios'

export default withSession(async (req, res) => {
  const apiToken = req.session.get('api_token')
  const user = req.session.get('user')

  if (!user) {
    return res.status(401).json({ message: 'Not authenticated' })
  }

  try {
    // Call backend via Nginx (never touch PHP-FPM directly)
    const url = `${process.env.BACKEND_API_HOST}/api/logout`
    await axios.post(url, null, {
      headers: { Authorization: `Bearer ${apiToken}` },
      validateStatus: () => true,
    })
  } catch (e) {
    // swallow errors – we will still clear local session
  }

  // Always destroy local session
  req.session.destroy()
  return res.json({ isLoggedIn: false })
})
