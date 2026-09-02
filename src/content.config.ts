import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const projects = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/projects' }),
  schema: z.object({
    status:   z.string().optional(),
    duration: z.string().optional(),
    stack:    z.array(z.string()).default([]),
    outcome:  z.string().optional(),
    skills:   z.array(z.string()).default([]),
    title: z.string(),
    description: z.string(),
    date: z.coerce.date(),
    tags: z.array(z.string()).optional(),
    category: z.string().optional(),
  }),
});

export const collections = { projects };
