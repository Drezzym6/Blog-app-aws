from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('blog', '0001_initial'),
    ]

    operations = [
        migrations.RemoveField(
            model_name='post',
            name='category',
        ),
        migrations.DeleteModel(
            name='Category',
        ),
        migrations.AddField(
            model_name='post',
            name='category',
            field=models.CharField(
                choices=[('e', 'Entertainment'), ('m', 'Music'), ('i', 'IT')],
                default='e',
                max_length=15,
            ),
        ),
    ]
