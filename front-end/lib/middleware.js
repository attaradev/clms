import {useRouter} from 'next/router'

export default async function auth({req, res}) {
    const user = req.session.get('user')

    if (!user) {
        return {
            redirect: {
                destination: '/',
                permanent: false,
            },
        }
    }


    // Use Next API bridge for browser-safe calls; avoids Docker-only hostnames leaking to the client
    let configBundle = {
        user: req.session.get('user'),
        apiToken: req.session.get('api_token'),
        backendUrl: "/api/bridge",
        hostUrl: process.env.BACKEND_API_HOST,
        authHeader: {"Authorization": "Bearer " + req.session.get('api_token')}
    }

    return {
        props: {
            user: req.session.get('user'),
            api_token: req.session.get('api_token'),
            configBundle: configBundle,
        },
    }
}


export async function unSecureAuth({req, res}) {
    const user = req.session.get('user')

    if (!user) {
        return {
            redirect: {
                destination: '/',
                permanent: false,
            },
        }
    }

    let configBundle = {
        user: req.session.get('user'),
        apiToken: req.session.get('api_token'),
        backendUrl: "/api/bridge",
        authHeader: {"Authorization": "Bearer " + req.session.get('api_token')}
    }
    return {
        props: {
            user: req.session.get('user'),
            apiToken: req.session.get('api_token'),
            backendUrl: "/api/bridge",
            configBundle: configBundle
        },
    }
}


export async function authGuard({req, res}) {
    const user = req.session.get('user')

    // redirect to dashboard if user is already logged in.
    if (user) {
        return {
            redirect: {
                destination: '/dashboard',
                permanent: false,
            },
        }
    }

    return {
        props: {
            url: process.env.BACKEND_API_HOST
        },
    }

}
