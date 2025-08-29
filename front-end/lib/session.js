// this file is a wrapper with defaults to be used in both API routes and `getServerSideProps` functions
import { withIronSession } from 'next-iron-session'

export default function withSession(handler) {
    const cookieSecure = process.env.COOKIE_SECURE
        ? process.env.COOKIE_SECURE === 'true'
        : process.env.NODE_ENV === 'production'

    return withIronSession(handler, {
        password: process.env.SECRET_COOKIE_PASSWORD,
        cookieName: 'clm.mw',
        cookieOptions: {
            secure: cookieSecure,
        },
    })
}
