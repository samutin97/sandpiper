import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/link_parsers.dart';

void main() {
  group("LinkParser.deep - sandpiper scheme", () {
    test("path form uses the fragment as the name", () {
      final link = LinkParser.deep("sandpiper://import/https://sub.com/x#MyProfile");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x"));
      expect(link.name, equals("MyProfile"));
    });

    test("path form without a fragment has an empty name", () {
      final link = LinkParser.deep("sandpiper://import/https://sub.com/x");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x"));
      expect(link.name, equals(""));
    });

    test("path form keeps the inner query string", () {
      final link = LinkParser.deep("sandpiper://import/https://sub.com/x?token=abc#Name");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x?token=abc"));
      expect(link.name, equals("Name"));
    });

    test("url-param form falls back to the fragment for the name", () {
      final link = LinkParser.deep("sandpiper://import?url=https%3A%2F%2Fsub.com%2Fx#MyProfile");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x"));
      expect(link.name, equals("MyProfile"));
    });

    test("url-param form prefers an explicit name= over the fragment", () {
      final link = LinkParser.deep("sandpiper://import?url=https%3A%2F%2Fsub.com%2Fx&name=Explicit#Fragment");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x"));
      expect(link.name, equals("Explicit"));
    });

    test("a host other than import is no link to import", () {
      expect(LinkParser.deep("sandpiper://install-config?url=https%3A%2F%2Fsub.com%2Fx"), isNull);
      expect(LinkParser.deep("sandpiper://x/settings/routing-options?routeRule=abc"), isNull);
    });

    test("import with nothing to import is null", () {
      expect(LinkParser.deep("sandpiper://import"), isNull);
      expect(LinkParser.deep("sandpiper://import/"), isNull);
    });
  });

  group("LinkParser.deep - schemes of other clients are not handled", () {
    for (final link in [
      "hiddify://import/https://sub.com/x",
      "hiddify://install-config?url=https%3A%2F%2Fsub.com%2Fx",
      "v2ray://install?url=https%3A%2F%2Fsub.com%2Fx&name=Sub",
      "v2rayng://install-config?url=https%3A%2F%2Fsub.com%2Fx",
      "clash://install-config?url=https%3A%2F%2Fsub.com%2Fx",
      "clashmeta://install-config?url=https%3A%2F%2Fsub.com%2Fx",
      "sing-box://import-remote-profile?url=https%3A%2F%2Fsub.com%2Fx",
    ]) {
      test(link, () => expect(LinkParser.deep(link), isNull));
    }

    test("only the app's own scheme is registered", () {
      expect(LinkParser.protocols, equals(["sandpiper"]));
    });
  });

  group("LinkParser.parse", () {
    test("plain https url is handled by simple()", () {
      final link = LinkParser.parse("https://example.com/sub?name=Foo");
      expect(link, isNotNull);
      expect(link!.url, equals("https://example.com/sub?name=Foo"));
      expect(link.name, equals("Foo"));
    });

    test("sandpiper deep link is handled by deep()", () {
      final link = LinkParser.parse("sandpiper://import?url=https%3A%2F%2Fsub.com%2Fx#Name");
      expect(link, isNotNull);
      expect(link!.url, equals("https://sub.com/x"));
      expect(link.name, equals("Name"));
    });
  });

  group("LinkParser.generateSubShareLink", () {
    test("keeps a non-default port", () {
      expect(
        LinkParser.generateSubShareLink("https://panel.example.com:2053/sub/abc", "Name"),
        equals("https://panel.example.com:2053/sub/abc#Name"),
      );
    });

    test("keeps userinfo, path and query", () {
      expect(
        LinkParser.generateSubShareLink("https://user:pw@example.com/sub/abc?x=1", "Name"),
        equals("https://user:pw@example.com/sub/abc?x=1#Name"),
      );
    });

    test("keeps the original fragment when no name is given", () {
      expect(LinkParser.generateSubShareLink("https://example.com/sub#Old"), equals("https://example.com/sub#Old"));
    });

    test("encodes the name as the fragment", () {
      expect(
        LinkParser.generateSubShareLink("https://example.com/sub", "My Profile"),
        equals("https://example.com/sub#My%20Profile"),
      );
    });
  });
}
