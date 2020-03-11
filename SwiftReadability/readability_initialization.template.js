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
    // https://github.com/mozilla/gecko-dev/blob/246928d59c6c11e1c3b3b0a6b00534bfc075e3c4/toolkit/components/reader/ReaderMode.jsm#L21-L31
    classesToPreserve: [
        "caption",
        "emoji",
        "hidden",
        "invisible",
        "sr-only",
        "visually-hidden",
        "visuallyhidden",
        "wp-caption",
        "wp-caption-text",
        "wp-smiley"
    ],
    charThreshold: ##CHAR_THRESHOLD##
}).parse();

JSON.stringify({
    title: article.title,
    byline: article.byline,
    content: article.content,
});

