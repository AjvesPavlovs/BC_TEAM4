# Use official Node.js image
FROM node:18-alpine

# Set working directory
WORKDIR /app

# Install dependencies first (for better layer caching)
COPY package*.json ./
RUN npm install --production

# Copy application source code
COPY . .

# Expose port the app runs on
EXPOSE 80

# Start the application
CMD ["npm", "start"]
