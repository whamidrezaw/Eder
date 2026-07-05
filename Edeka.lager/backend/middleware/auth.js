const jwt  = require('jsonwebtoken');
const User = require('../models/User');

module.exports = async (req, res, next) => {
  try {
    const header = req.headers.authorization || '';
    const token  = header.startsWith('Bearer ') ? header.slice(7) : null;

    if (!token)
      return res.status(401).json({ message: 'Kein Token vorhanden' });

    // FIX #3: Ablauf-Fehler gezielt abfangen
    let decoded;
    try {
      decoded = jwt.verify(token, process.env.JWT_SECRET);
    } catch (jwtErr) {
      const expired = jwtErr.name === 'TokenExpiredError';
      return res.status(401).json({
        message: expired ? 'Token abgelaufen – bitte erneut einloggen' : 'Token ungültig'
      });
    }

    // FIX #1: loginHistory ausschließen (vertrauliche Daten nicht im req.user)
    const user = await User.findById(decoded.id).select('-password -loginHistory');

    if (!user)
      return res.status(401).json({ message: 'Benutzer nicht gefunden' });

    // FIX #2: deaktivierte Benutzer blockieren
    if (!user.isActive)
      return res.status(403).json({ message: 'Konto deaktiviert – Zugriff verweigert' });

    req.user = user;
    next();
  } catch (err) {
    return res.status(401).json({ message: 'Authentifizierung fehlgeschlagen' });
  }
};
