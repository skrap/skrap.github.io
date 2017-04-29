# This & Me

This is a blog, written by an engineer.  If you think this stuff is neat, I'm afraid you might be a giant nerd.

I am a nerd, too!  I like computers, and have been a professional software engineer since 2003.  I am a generalist, which basically means I like trying lots of different things.

Feel free to get in touch with me at [jonah@petri.us](mailto:jonah@petri.us).

# Recent Posts:

{% for post in site.posts %}
### {{ post.title }} - {{ post.date | date: "%a, %b %d, %Y"}}
{{ post.excerpt }}
[Read more…]({{ post.url }})
{% endfor %}
