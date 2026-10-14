import crypto from 'crypto';

const secret = process.env.JWT_SECRET || '';

// JWT 토큰 확인 후 sub(사용자 ID) 반환, 유효하지 않으면 빈 값 반환
function subject(r) {
    try {
        const authorization = (r.headersIn.Authorization || '').trim();
        if (!/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/i.test(authorization)) {
            throw new Error('invalid bearer');
        }
        const parts = authorization.slice(7).split('.');
        const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
        if (header.alg !== 'HS256' || header.crit !== undefined || header.b64 === false) {
            throw new Error('invalid algorithm');
        }
        const signature = Buffer.from(parts[2], 'base64url');
        const expected = crypto.createHmac('sha256', secret)
            .update(parts[0] + '.' + parts[1]).digest();
        if (signature.length !== expected.length || signature.toString('base64url') !== parts[2]) {
            throw new Error('invalid signature');
        }
        let difference = 0;
        for (let i = 0; i < expected.length; i++) difference |= signature[i] ^ expected[i];
        if (difference !== 0) throw new Error('invalid signature');
        const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
        const now = Math.floor(Date.now() / 1000);
        if (!Number.isInteger(claims.exp) || claims.exp <= now ||
            (claims.nbf !== undefined && (!Number.isInteger(claims.nbf) || claims.nbf > now)) ||
            typeof claims.sub !== 'string' || !/^[1-9][0-9]{0,18}$/.test(claims.sub) ||
            !['USER', 'ADMIN'].includes(claims.role)) {
            throw new Error('invalid claims');
        }
        return claims.sub;
    } catch (e) {
        return '';
    }
}

// 인증이 필요한 API 요청에서 유효한 JWT 토큰이 없으면 401 반환
function authorize(r) {
    const publicPath = /^\/api\/(?:auth\/oauth(?:\/|$)|auth\/(?:kakao\/callback|refresh)$|health\/ping\/(?:mysql|fastapi)$|actuator\/health\/(?:liveness|readiness)$|ws(?:\/|$)|error$)/;
    if (r.method === 'OPTIONS' || publicPath.test(r.uri) || r.variables.rate_limit_user) {
        r.decline();
    } else {
        r.return(401);
    }
}

export default { subject, authorize };
