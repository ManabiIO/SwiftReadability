// https://github.com/mozilla/readability

var loc = document.location;
var uri = {
    spec: loc.href,
    host: loc.host,
    prePath: loc.protocol + "//" + loc.host,
    scheme: loc.protocol.substr(0, loc.protocol.indexOf(":")),
    pathBase: loc.protocol + "//" + loc.host + loc.pathname.substr(0, loc.pathname.lastIndexOf("/") + 1)
};
var article = new Readability(uri, document, {
    charThreshold: ##CHAR_THRESHOLD##
}).parse();

JSON.stringify({
    title: article.title,
    byline: article.byline,
    content: article.content,
});

